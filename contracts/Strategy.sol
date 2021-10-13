// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/math/Math.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/liquity/IPriceFeed.sol";
import "../interfaces/liquity/IStabilityPool.sol";
import "../interfaces/uniswap/ISwapRouter.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // Liquity USD pegged stablecoin
    IERC20 internal constant LUSD =
        IERC20(0x5f98805A4E8be255a32880FDeC7F6728C6568bA0);

    // LQTY rewards accrue to Stability Providers who deposit LUSD to the Stability Pool
    IERC20 internal constant LQTY =
        IERC20(0x6DEA81C8171D0bA574754EF6F8b412F2Ed88c54D);

    // Source of liquidity to repay debt from liquidated troves
    IStabilityPool internal constant stabilityPool =
        IStabilityPool(0x66017D22b0f8556afDd19FC67041899Eb65a21bb);

    // Chainlink ETH:USD with Tellor ETH:USD as fallback
    IPriceFeed internal constant priceFeed =
        IPriceFeed(0x4c517D4e2C851CA76d7eC94B805269Df0f2201De);

    // Uniswap v3 router to do LQTY->ETH
    ISwapRouter internal constant router =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // Wrapped Ether - Used for swaps routing
    IERC20 internal constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // DAI - Used for swaps routing
    IERC20 internal constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

    function name() external view override returns (string memory) {
        return "StrategyLiquityStabilityPoolLUSD";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 ethBalance = address(this).balance + stabilityPool.getDepositorETHGain(address(this));
        
        // We ignore LQTY rewards when reporting estimated assets
        // We also assume for the sake of the estimate that LUSD keeps its 1:1 peg to USD
        return
            balanceOfWant()
            .add(
                stabilityPool.getCompoundedLUSDDeposit(address(this))
            )
            .add(ethBalance.mul(priceFeed.lastGoodPrice()).div(1e18));
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // Claim rewards and sell them for more LUSD
        _claimRewards();

        // At this point all ETH and LQTY has been converted to LUSD
        uint256 totalAssetsAfterProfit = balanceOfWant().add(stabilityPool.getCompoundedLUSDDeposit(address(this)));

        _profit = totalAssetsAfterProfit > totalDebt
            ? totalAssetsAfterProfit.sub(totalDebt)
            : 0;

        uint256 _amountFreed;
        (_amountFreed, _loss) = liquidatePosition(
            _debtOutstanding.add(_profit)
        );
        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // Provide any leftover balance to the stability pool
        // Use zero address for frontend as we are interacting with the contracts directly
        if (balanceOfWant() > 0) {
            stabilityPool.provideToSP(balanceOfWant(), address(0));
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balance = balanceOfWant();

        // Check if we can handle it without withdrawing from stability pool
        if (balance >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        // Only need to free the amount of want not readily available
        uint256 amountToWithdraw = _amountNeeded.sub(balance);

        // Cannot withdraw more than what we have in deposit
        amountToWithdraw = Math.min(
            amountToWithdraw,
            stabilityPool.getCompoundedLUSDDeposit(address(this))
        );
        stabilityPool.withdrawFromSP(amountToWithdraw);

        // After withdrawing from the stability pool it could happen that we have
        // enough LQTY / ETH to cover a loss before reporting it.
        // However, doing a swap at this point could make withdrawals insecure
        // and front-runnable, so we assume LUSD that cannot be returned is a 
        // realized loss.
        uint256 looseWant = balanceOfWant();
        if (_amountNeeded > looseWant) {
            _liquidatedAmount = looseWant;
            _loss = _amountNeeded.sub(looseWant);
        } else {
            _liquidatedAmount = _amountNeeded;
            _loss = 0;
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(estimatedTotalAssets());
    }

    function prepareMigration(address _newStrategy) internal override {
        // Withdraw entire LUSD balance from Stability Pool
        // ETH + LQTY gains should be harvested before migrating
        // `migrate` will automatically forward all `want` in this strategy to the new one
        stabilityPool.withdrawFromSP(
            stabilityPool.getCompoundedLUSDDeposit(address(this))
        );
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    function _checkAllowance(
        address _contract,
        IERC20 _token,
        uint256 _amount
    ) internal {
        if (_token.allowance(address(this), _contract) < _amount) {
            _token.safeApprove(_contract, 0);
            _token.safeApprove(_contract, type(uint256).max);
        }
    }


    function _claimRewards() internal {
        // Withdraw minimum amount to force LQTY and ETH to be claimed
        stabilityPool.withdrawFromSP(1);

        // Convert LQTY rewards to DAI
        _sellLQTYforDAI();

        // Convert ETH obtained from liquidations to DAI
        _sellETHforDAI();

        // Use DAI-LUSD 0.05% pool in Uniswap V3 to get LUSD
        _sellDAIforLUSD();
    }

    // ----------------- PUBLIC BALANCES -----------------

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function totalLQTYRewards() public view returns (uint256) {
        return LQTY.balanceOf(address(this))
            .add(stabilityPool.getDepositorLQTYGain(address(this)));
    }

    function totalETHBalance() public view returns (uint256) {
        return address(this).balance
            .add(stabilityPool.getDepositorETHGain(address(this)));
    }

    // ----------------- TOKEN CONVERSIONS -----------------

    function _sellLQTYforDAI() internal {
        _checkAllowance(address(router), LQTY, LQTY.balanceOf(address(this)));

        bytes memory path =
                abi.encodePacked(
                    address(LQTY),  // LQTY-ETH 0.3%
                    uint24(3000),
                    address(WETH),           // ETH-DAI 0.3%
                    uint24(3000),
                    address(DAI)
                );

        router.exactInput(ISwapRouter.ExactInputParams(
                    path,
                    address(this),
                    now,
                    LQTY.balanceOf(address(this)),
                    0
                ));
    }

    function _sellETHforDAI() internal {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams(
            address(WETH),   // tokenIn
            address(DAI),    // tokenOut
            3000,    // 0.3% fee
            address(this),  // recipient
            now,   // deadline
            address(this).balance, // amountIn
            0, // amountOut
            0 // sqrtPriceLimitX96
        );
        
        router.exactInputSingle{ value: address(this).balance }(params);
        router.refundETH();
    }

    function _sellDAIforLUSD() internal {
        _checkAllowance(address(router), DAI, DAI.balanceOf(address(this)));

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams(
            address(DAI),   // tokenIn
            address(LUSD),    // tokenOut
            500,    // 0.05% fee
            address(this),  // recipient
            now,   // deadline
            DAI.balanceOf(address(this)), // amountIn
            0, // amountOut
            0 // sqrtPriceLimitX96
        );
        router.exactInputSingle(params);
    }

    // Important to receive ETH
    receive() payable external {}
}
