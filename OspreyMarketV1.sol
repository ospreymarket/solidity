// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PToken.sol";
import "./ErrorReporter.sol";
import "./PriceOracle.sol";
import "./Core/ComptrollerInterface.sol";
import "./Core/ComptrollerStorage.sol";
import "./OspreyMarketsUpgradable.sol";
import "./Governance/OspreyToken.sol";


contract OspreyMarketsV1 is
    ComptrollerV9Storage,
    ComptrollerInterface,
    ComptrollerErrorReporter,
    ExponentialNoError
{
    /// @notice Emitted when an admin supports a market
    event MarketListed(PToken pToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(PToken pToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(PToken pToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(
        uint oldCloseFactorMantissa,
        uint newCloseFactorMantissa
    );

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(
        PToken pToken,
        uint oldCollateralFactorMantissa,
        uint newCollateralFactorMantissa
    );

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(
        uint oldLiquidationIncentiveMantissa,
        uint newLiquidationIncentiveMantissa
    );

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(
        PriceOracle oldPriceOracle,
        PriceOracle newPriceOracle
    );

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(PToken pToken, string action, bool pauseState);

    /// @notice Emitted when a new borrow-side Token speed is calculated for a market
    event RewardsBorrowSpeedUpdated(PToken indexed pToken, uint newSpeed);

    /// @notice Emitted when a new supply-side Token speed is calculated for a market
    event RewardsSupplySpeedUpdated(PToken indexed pToken, uint newSpeed);

    /// @notice Emitted when a new Token speed is set for a contributor
    event ContributorRewardSpeedUpdated(
        address indexed contributor,
        uint newSpeed
    );

    /// @notice Emitted when Token is distributed to a supplier
    event DistributedSupplierTok(
        PToken indexed pToken,
        address indexed supplier,
        uint compDelta,
        uint compSupplyIndex
    );

    /// @notice Emitted when Token is distributed to a borrower
    event DistributedBorrowerTok(
        PToken indexed pToken,
        address indexed borrower,
        uint compDelta,
        uint compBorrowIndex
    );

    /// @notice Emitted when borrow cap for a pToken is changed
    event NewBorrowCap(PToken indexed pToken, uint newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(
        address oldBorrowCapGuardian,
        address newBorrowCapGuardian
    );

    /// @notice Emitted when Token is granted by admin
    event Granted(address recipient, uint amount);

    /// @notice Emitted when Token accrued for a user has been manually adjusted.
    event TokAccruedAdjusted(
        address indexed user,
        uint oldTokAccrued,
        uint newTokAccrued
    );

    /// @notice Emitted when Token receivable for a user has been updated.
    event TokReceivableUpdated(
        address indexed user,
        uint oldTokReceivable,
        uint newTokReceivable
    );

    /// @notice The initial Token index for a market
    uint224 public constant compInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(
        address account
    ) external view returns (PToken[] memory) {
        PToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param pToken The pToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(
        address account,
        PToken pToken
    ) external view returns (bool) {
        return markets[address(pToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param pTokens The list of addresses of the pToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(
        address[] memory pTokens
    ) public override returns (uint[] memory) {
        uint len = pTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            PToken pToken = PToken(pTokens[i]);

            results[i] = uint(addToMarketInternal(pToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param pToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(
        PToken pToken,
        address borrower
    ) internal returns (Error) {
        Market storage marketToJoin = markets[address(pToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(pToken);

        emit MarketEntered(pToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param pTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(
        address pTokenAddress
    ) external override returns (uint) {
        PToken pToken = PToken(pTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the pToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = pToken
            .getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return
                fail(
                    Error.NONZERO_BORROW_BALANCE,
                    FailureInfo.EXIT_MARKET_BALANCE_OWED
                );
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(
            pTokenAddress,
            msg.sender,
            tokensHeld
        );
        if (allowed != 0) {
            return
                failOpaque(
                    Error.REJECTION,
                    FailureInfo.EXIT_MARKET_REJECTION,
                    allowed
                );
        }

        Market storage marketToExit = markets[address(pToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set pToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete pToken from the account’s list of assets */
        // load into memory for faster iteration
        PToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == pToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        PToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(pToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param pToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(
        address pToken,
        address minter,
        uint mintAmount
    ) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[pToken], "mint is paused");

        // Shh - currently unused
        minter;
        mintAmount;

        if (!markets[pToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updateTokSupplyIndex(pToken);
        distributeSupplierTok(pToken, minter);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param pToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(
        address pToken,
        address minter,
        uint actualMintAmount,
        uint mintTokens
    ) external override {
        // Shh - currently unused
        pToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param pToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of pTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(
        address pToken,
        address redeemer,
        uint redeemTokens
    ) external override returns (uint) {
        uint allowed = redeemAllowedInternal(pToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateTokSupplyIndex(pToken);
        distributeSupplierTok(pToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(
        address pToken,
        address redeemer,
        uint redeemTokens
    ) internal view returns (uint) {
        if (!markets[pToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[pToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(
            redeemer,
            PToken(pToken),
            redeemTokens,
            0
        );
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param pToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(
        address pToken,
        address redeemer,
        uint redeemAmount,
        uint redeemTokens
    ) external override {
        // Shh - currently unused
        pToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param pToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(
        address pToken,
        address borrower,
        uint borrowAmount
    ) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[pToken], "borrow is paused");

        if (!markets[pToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[pToken].accountMembership[borrower]) {
            // only pTokens may call borrowAllowed if borrower not in market
            require(msg.sender == pToken, "sender must be pToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(PToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[pToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(PToken(pToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        uint borrowCap = borrowCaps[pToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = PToken(pToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(
            borrower,
            PToken(pToken),
            0,
            borrowAmount
        );
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: PToken(pToken).borrowIndex()});
        updateTokBorrowIndex(pToken, borrowIndex);
        distributeBorrowerTok(pToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param pToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(
        address pToken,
        address borrower,
        uint borrowAmount
    ) external override {
        // Shh - currently unused
        pToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param pToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address pToken,
        address payer,
        address borrower,
        uint repayAmount
    ) external override returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[pToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: PToken(pToken).borrowIndex()});
        updateTokBorrowIndex(pToken, borrowIndex);
        distributeBorrowerTok(pToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param pToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address pToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex
    ) external override {
        // Shh - currently unused
        pToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external override returns (uint) {
        // Shh - currently unused
        liquidator;

        if (
            !markets[pTokenBorrowed].isListed ||
            !markets[pTokenCollateral].isListed
        ) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        uint borrowBalance = PToken(pTokenBorrowed).borrowBalanceStored(
            borrower
        );

        /* allow accounts to be liquidated if the market is deprecated */
        if (isDeprecated(PToken(pTokenBorrowed))) {
            require(
                borrowBalance >= repayAmount,
                "Can not repay more than the total borrow"
            );
        } else {
            /* The borrower must have shortfall in order to be liquidatable */
            (Error err, , uint shortfall) = getAccountLiquidityInternal(
                borrower
            );
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            if (shortfall == 0) {
                return uint(Error.INSUFFICIENT_SHORTFALL);
            }

            /* The liquidator may not repay more than what is allowed by the closeFactor */
            uint maxClose = mul_ScalarTruncate(
                Exp({mantissa: closeFactorMantissa}),
                borrowBalance
            );
            if (repayAmount > maxClose) {
                return uint(Error.TOO_MUCH_REPAY);
            }
        }
        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens
    ) external override {
        // Shh - currently unused
        pTokenBorrowed;
        pTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (
            !markets[pTokenCollateral].isListed ||
            !markets[pTokenBorrowed].isListed
        ) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (
            PToken(pTokenCollateral).comptroller() !=
            PToken(pTokenBorrowed).comptroller()
        ) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateTokSupplyIndex(pTokenCollateral);
        distributeSupplierTok(pTokenCollateral, borrower);
        distributeSupplierTok(pTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external override {
        // Shh - currently unused
        pTokenCollateral;
        pTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param pToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of pTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(
        address pToken,
        address src,
        address dst,
        uint transferTokens
    ) external override returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(pToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateTokSupplyIndex(pToken);
        distributeSupplierTok(pToken, src);
        distributeSupplierTok(pToken, dst);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param pToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of pTokens to transfer
     */
    function transferVerify(
        address pToken,
        address src,
        address dst,
        uint transferTokens
    ) external override {
        // Shh - currently unused
        pToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `pTokenBalance` is the number of pTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint pTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(
        address account
    ) public view returns (uint, uint, uint) {
        (
            Error err,
            uint liquidity,
            uint shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                PToken(address(0)),
                0,
                0
            );

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(
        address account
    ) internal view returns (Error, uint, uint) {
        return
            getHypotheticalAccountLiquidityInternal(
                account,
                PToken(address(0)),
                0,
                0
            );
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param pTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address pTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) public view returns (uint, uint, uint) {
        (
            Error err,
            uint liquidity,
            uint shortfall
        ) = getHypotheticalAccountLiquidityInternal(
                account,
                PToken(pTokenModify),
                redeemTokens,
                borrowAmount
            );
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param pTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral pToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        PToken pTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) internal view returns (Error, uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        PToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            PToken asset = assets[i];

            // Read the balances and exchange rate from the pToken
            (
                oErr,
                vars.pTokenBalance,
                vars.borrowBalance,
                vars.exchangeRateMantissa
            ) = asset.getAccountSnapshot(account);
            if (oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({
                mantissa: markets[address(asset)].collateralFactorMantissa
            });
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(
                mul_(vars.collateralFactor, vars.exchangeRate),
                vars.oraclePrice
            );

            // sumCollateral += tokensToDenom * pTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(
                vars.tokensToDenom,
                vars.pTokenBalance,
                vars.sumCollateral
            );

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );

            // Calculate effects of interacting with pTokenModify
            if (asset == pTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.tokensToDenom,
                    redeemTokens,
                    vars.sumBorrowPlusEffects
                );

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.oraclePrice,
                    borrowAmount,
                    vars.sumBorrowPlusEffects
                );
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (
                Error.NO_ERROR,
                vars.sumCollateral - vars.sumBorrowPlusEffects,
                0
            );
        } else {
            return (
                Error.NO_ERROR,
                0,
                vars.sumBorrowPlusEffects - vars.sumCollateral
            );
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in pToken.liquidateBorrowFresh)
     * @param pTokenBorrowed The address of the borrowed pToken
     * @param pTokenCollateral The address of the collateral pToken
     * @param actualRepayAmount The amount of pTokenBorrowed underlying to convert into pTokenCollateral tokens
     * @return (errorCode, number of pTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(
        address pTokenBorrowed,
        address pTokenCollateral,
        uint actualRepayAmount
    ) external view override returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(
            PToken(pTokenBorrowed)
        );
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(
            PToken(pTokenCollateral)
        );
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = PToken(pTokenCollateral)
            .exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(
            Exp({mantissa: liquidationIncentiveMantissa}),
            Exp({mantissa: priceBorrowedMantissa})
        );
        denominator = mul_(
            Exp({mantissa: priceCollateralMantissa}),
            Exp({mantissa: exchangeRateMantissa})
        );
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
     * @notice Sets a new price oracle for the comptroller
     * @dev Admin function to set a new price oracle
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK
                );
        }

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets the closeFactor used when liquidating borrows
     * @dev Admin function to set closeFactor
     * @param newCloseFactorMantissa New close factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure
     */
    function _setCloseFactor(
        uint newCloseFactorMantissa
    ) external returns (uint) {
        // Check caller is admin
        require(msg.sender == admin, "only admin can set close factor");

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev Admin function to set per-market collateralFactor
     * @param pToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(
        PToken pToken,
        uint newCollateralFactorMantissa
    ) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK
                );
        }

        // Verify market is listed
        Market storage market = markets[address(pToken)];
        if (!market.isListed) {
            return
                fail(
                    Error.MARKET_NOT_LISTED,
                    FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS
                );
        }

        Exp memory newCollateralFactorExp = Exp({
            mantissa: newCollateralFactorMantissa
        });

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return
                fail(
                    Error.INVALID_COLLATERAL_FACTOR,
                    FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION
                );
        }

        // If collateral factor != 0, fail if price == 0
        if (
            newCollateralFactorMantissa != 0 &&
            oracle.getUnderlyingPrice(pToken) == 0
        ) {
            return
                fail(
                    Error.PRICE_ERROR,
                    FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE
                );
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(
            pToken,
            oldCollateralFactorMantissa,
            newCollateralFactorMantissa
        );

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Sets liquidationIncentive
     * @dev Admin function to set liquidationIncentive
     * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setLiquidationIncentive(
        uint newLiquidationIncentiveMantissa
    ) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK
                );
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(
            oldLiquidationIncentiveMantissa,
            newLiquidationIncentiveMantissa
        );

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Admin function to set isListed and add support for the market
     * @param pToken The address of the market (token) to list
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(PToken pToken) external returns (uint) {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SUPPORT_MARKET_OWNER_CHECK
                );
        }

        if (markets[address(pToken)].isListed) {
            return
                fail(
                    Error.MARKET_ALREADY_LISTED,
                    FailureInfo.SUPPORT_MARKET_EXISTS
                );
        }

        pToken.isCToken(); // Sanity check to make sure its really a PToken

        // Note that isComped is not in active use anymore
        Market storage newMarket = markets[address(pToken)];
        newMarket.isListed = true;
        newMarket.isComped = false;
        newMarket.collateralFactorMantissa = 0;

        _addMarketInternal(address(pToken));
        _initializeMarket(address(pToken));

        emit MarketListed(pToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address pToken) internal {
        for (uint i = 0; i < allMarkets.length; i++) {
            require(allMarkets[i] != PToken(pToken), "market already added");
        }
        allMarkets.push(PToken(pToken));
    }

    function _initializeMarket(address pToken) internal {
        uint32 blockNumber = safe32(
            getBlockNumber(),
            "block number exceeds 32 bits"
        );

        CompMarketState storage supplyState = compSupplyState[pToken];
        CompMarketState storage borrowState = compBorrowState[pToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = compInitialIndex;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = compInitialIndex;
        }

        /*
         * Update market state block numbers
         */
        supplyState.block = borrowState.block = blockNumber;
    }

    /**
     * @notice Set the given borrow caps for the given pToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
     * @param pTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function _setMarketBorrowCaps(
        PToken[] calldata pTokens,
        uint[] calldata newBorrowCaps
    ) external {
        require(
            msg.sender == admin || msg.sender == borrowCapGuardian,
            "only admin or borrow cap guardian can set borrow caps"
        );

        uint numMarkets = pTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(
            numMarkets != 0 && numMarkets == numBorrowCaps,
            "invalid input"
        );

        for (uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(pTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(pTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return
                fail(
                    Error.UNAUTHORIZED,
                    FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK
                );
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(PToken pToken, bool state) public returns (bool) {
        require(
            markets[address(pToken)].isListed,
            "cannot pause a market that is not listed"
        );
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(pToken)] = state;
        emit ActionPaused(pToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(PToken pToken, bool state) public returns (bool) {
        require(
            markets[address(pToken)].isListed,
            "cannot pause a market that is not listed"
        );
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(pToken)] = state;
        emit ActionPaused(pToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(
            msg.sender == pauseGuardian || msg.sender == admin,
            "only pause guardian and admin can pause"
        );
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(OspreyMarketsUpgradable unitroller) public {
        require(
            msg.sender == unitroller.admin(),
            "only unitroller admin can change brains"
        );
        require(
            unitroller._acceptImplementation() == 0,
            "change not authorized"
        );
    }

    /// @notice Delete this function after proposal 65 is executed
    function fixBadAccruals(
        address[] calldata affectedUsers,
        uint[] calldata amounts
    ) external {
        require(msg.sender == admin, "Only admin can call this function"); // Only the timelock can call this function
        require(
            !proposal65FixExecuted,
            "Already executed this one-off function"
        ); // Require that this function is only called once
        require(affectedUsers.length == amounts.length, "Invalid input");

        // Loop variables
        address user;
        uint currentAccrual;
        uint amountToSubtract;
        uint newAccrual;

        // Iterate through all affected users
        for (uint i = 0; i < affectedUsers.length; ++i) {
            user = affectedUsers[i];
            currentAccrual = compAccrued[user];

            amountToSubtract = amounts[i];

            // The case where the user has claimed and received an incorrect amount of Token.
            // The user has less currently accrued than the amount they incorrectly received.
            if (amountToSubtract > currentAccrual) {
                // Amount of Token the user owes the protocol
                uint accountReceivable = amountToSubtract - currentAccrual; // Underflow safe since amountToSubtract > currentAccrual

                uint oldReceivable = compReceivable[user];
                uint newReceivable = add_(oldReceivable, accountReceivable);

                // Accounting: record the Token debt for the user
                compReceivable[user] = newReceivable;

                emit TokReceivableUpdated(user, oldReceivable, newReceivable);

                amountToSubtract = currentAccrual;
            }

            if (amountToSubtract > 0) {
                // Subtract the bad accrual amount from what they have accrued.
                // Users will keep whatever they have correctly accrued.
                compAccrued[user] = newAccrual = sub_(
                    currentAccrual,
                    amountToSubtract
                );

                emit TokAccruedAdjusted(user, currentAccrual, newAccrual);
            }
        }

        proposal65FixExecuted = true; // Makes it so that this function cannot be called again
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /*** Rewards Distribution ***/

    /**
     * @notice Set Token speed for a single market
     * @param pToken The market whose Token speed to update
     * @param supplySpeed New supply-side Token speed for market
     * @param borrowSpeed New borrow-side Token speed for market
     */
    function setRewardSpeedInternal(
        PToken pToken,
        uint supplySpeed,
        uint borrowSpeed
    ) internal {
        Market storage market = markets[address(pToken)];
        require(market.isListed, "comp market is not listed");

        if (compSupplySpeeds[address(pToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. Token accrued properly for the old speed, and
            //  2. Token accrued at the new speed starts after this block.
            updateTokSupplyIndex(address(pToken));

            // Update speed and emit event
            compSupplySpeeds[address(pToken)] = supplySpeed;
            emit RewardsSupplySpeedUpdated(pToken, supplySpeed);
        }

        if (compBorrowSpeeds[address(pToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. Token accrued properly for the old speed, and
            //  2. Token accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({mantissa: pToken.borrowIndex()});
            updateTokBorrowIndex(address(pToken), borrowIndex);

            // Update speed and emit event
            compBorrowSpeeds[address(pToken)] = borrowSpeed;
            emit RewardsBorrowSpeedUpdated(pToken, borrowSpeed);
        }
    }

    /**
     * @notice Accrue Token to the market by updating the supply index
     * @param pToken The market whose supply index to update
     * @dev Index is a cumulative sum of the Token per pToken accrued.
     */
    function updateTokSupplyIndex(address pToken) internal {
        CompMarketState storage supplyState = compSupplyState[pToken];
        uint supplySpeed = compSupplySpeeds[pToken];
        uint32 blockNumber = safe32(
            getBlockNumber(),
            "block number exceeds 32 bits"
        );
        uint deltaBlocks = sub_(uint(blockNumber), uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = PToken(pToken).totalSupply();
            uint compAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0
                ? fraction(compAccrued, supplyTokens)
                : Double({mantissa: 0});
            supplyState.index = safe224(
                add_(Double({mantissa: supplyState.index}), ratio).mantissa,
                "new index exceeds 224 bits"
            );
            supplyState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }
    }

    /**
     * @notice Accrue Token to the market by updating the borrow index
     * @param pToken The market whose borrow index to update
     * @dev Index is a cumulative sum of the Token per pToken accrued.
     */
    function updateTokBorrowIndex(
        address pToken,
        Exp memory marketBorrowIndex
    ) internal {
        CompMarketState storage borrowState = compBorrowState[pToken];
        uint borrowSpeed = compBorrowSpeeds[pToken];
        uint32 blockNumber = safe32(
            getBlockNumber(),
            "block number exceeds 32 bits"
        );
        uint deltaBlocks = sub_(uint(blockNumber), uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(
                PToken(pToken).totalBorrows(),
                marketBorrowIndex
            );
            uint compAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0
                ? fraction(compAccrued, borrowAmount)
                : Double({mantissa: 0});
            borrowState.index = safe224(
                add_(Double({mantissa: borrowState.index}), ratio).mantissa,
                "new index exceeds 224 bits"
            );
            borrowState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber;
        }
    }

    /**
     * @notice Calculate Token accrued by a supplier and possibly transfer it to them
     * @param pToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute Token to
     */
    function distributeSupplierTok(address pToken, address supplier) internal {
        // TODO: Don't distribute supplier Token if the user is not in the supplier market.
        // This check should be as gas efficient as possible as distributeSupplierTok is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        CompMarketState storage supplyState = compSupplyState[pToken];
        uint supplyIndex = supplyState.index;
        uint supplierIndex = compSupplierIndex[pToken][supplier];

        // Update supplier's index to the current index since we are distributing accrued Token
        compSupplierIndex[pToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= compInitialIndex) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with Token accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = compInitialIndex;
        }

        // Calculate change in the cumulative sum of the Token per pToken accrued
        Double memory deltaIndex = Double({
            mantissa: sub_(supplyIndex, supplierIndex)
        });

        uint supplierTokens = PToken(pToken).balanceOf(supplier);

        // Calculate Token accrued: pTokenAmount * accruedPerPToken
        uint supplierDelta = mul_(supplierTokens, deltaIndex);

        uint supplierAccrued = add_(compAccrued[supplier], supplierDelta);
        compAccrued[supplier] = supplierAccrued;

        emit DistributedSupplierTok(
            PToken(pToken),
            supplier,
            supplierDelta,
            supplyIndex
        );
    }

    /**
     * @notice Calculate Token accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param pToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute Token to
     */
    function distributeBorrowerTok(
        address pToken,
        address borrower,
        Exp memory marketBorrowIndex
    ) internal {
        // TODO: Don't distribute supplier Token if the user is not in the borrower market.
        // This check should be as gas efficient as possible as distributeBorrowerTok is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        CompMarketState storage borrowState = compBorrowState[pToken];
        uint borrowIndex = borrowState.index;
        uint borrowerIndex = compBorrowerIndex[pToken][borrower];

        // Update borrowers's index to the current index since we are distributing accrued Token
        compBorrowerIndex[pToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= compInitialIndex) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with Token accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = compInitialIndex;
        }

        // Calculate change in the cumulative sum of the Token per borrowed unit accrued
        Double memory deltaIndex = Double({
            mantissa: sub_(borrowIndex, borrowerIndex)
        });

        uint borrowerAmount = div_(
            PToken(pToken).borrowBalanceStored(borrower),
            marketBorrowIndex
        );

        // Calculate Token accrued: pTokenAmount * accruedPerBorrowedUnit
        uint borrowerDelta = mul_(borrowerAmount, deltaIndex);

        uint borrowerAccrued = add_(compAccrued[borrower], borrowerDelta);
        compAccrued[borrower] = borrowerAccrued;

        emit DistributedBorrowerTok(
            PToken(pToken),
            borrower,
            borrowerDelta,
            borrowIndex
        );
    }

    /**
     * @notice Calculate additional accrued Token for a contributor since last accrual
     * @param contributor The address to calculate contributor rewards for
     */
    function updateContributorRewards(address contributor) public {
        uint compSpeed = compContributorSpeeds[contributor];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, lastContributorBlock[contributor]);
        if (deltaBlocks > 0 && compSpeed > 0) {
            uint newAccrued = mul_(deltaBlocks, compSpeed);
            uint contributorAccrued = add_(
                compAccrued[contributor],
                newAccrued
            );

            compAccrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumber;
        }
    }

    /**
     * @notice Claim all the incentive tokens accrued by holder in all markets
     * @param holder The address to claim tokens for
     */
    function claim(address holder) public {
        return claim(holder, allMarkets);
    }

    /**
     * @notice Claim all the comp accrued by holder in the specified markets
     * @param holder The address to claim tokens for
     * @param pTokens The list of markets to claim tokens in
     */
    function claim(address holder, PToken[] memory pTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claim(holders, pTokens, true, true);
    }

    /**
     * @notice Claim all comp accrued by the holders
     * @param holders The addresses to claim tokens for
     * @param pTokens The list of markets to claim tokens in
     * @param borrowers Whether or not to claim tokens earned by borrowing
     * @param suppliers Whether or not to claim tokens earned by supplying
     */
    function claim(
        address[] memory holders,
        PToken[] memory pTokens,
        bool borrowers,
        bool suppliers
    ) public {
        for (uint i = 0; i < pTokens.length; i++) {
            PToken pToken = pTokens[i];
            require(markets[address(pToken)].isListed, "market must be listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: pToken.borrowIndex()});
                updateTokBorrowIndex(address(pToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    distributeBorrowerTok(
                        address(pToken),
                        holders[j],
                        borrowIndex
                    );
                }
            }
            if (suppliers == true) {
                updateTokSupplyIndex(address(pToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplierTok(address(pToken), holders[j]);
                }
            }
        }
        for (uint j = 0; j < holders.length; j++) {
            compAccrued[holders[j]] = grantInternal(
                holders[j],
                compAccrued[holders[j]]
            );
        }
    }

    /**
     * @notice Transfer tokens to the user
     * @dev Note: If there is not enough tokens, we do not perform the transfer all.
     * @param user The address of the user to transfer tokens to
     * @param amount The amount of tokens to (possibly) transfer
     * @return The amount of tokens which was NOT transferred to the user
     */
    function grantInternal(
        address user,
        uint amount
    ) internal returns (uint) {
        OspreyToken comp = OspreyToken(getTokenAddress());
        uint compRemaining = comp.balanceOf(address(this));
        if (amount > 0 && amount <= compRemaining) {
            comp.transfer(user, amount);
            return 0;
        }
        return amount;
    }

    /*** Distribution Admin ***/

    /**
     * @notice Transfer tokens to the recipient
     * @dev Note: If there is not enough tokens, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer tokens to
     * @param amount The amount of tokens to (possibly) transfer
     */
    function _grant(address recipient, uint amount) public {
        require(adminOrInitializing(), "only admin can grant comp");
        uint amountLeft = grantInternal(recipient, amount);
        require(amountLeft == 0, "insufficient comp for grant");
        emit Granted(recipient, amount);
    }

    /**
     * @notice Set tokens borrow and supply speeds for the specified markets.
     * @param pTokens The markets whose tokens speed to update.
     * @param supplySpeeds New supply-side tokens speed for the corresponding market.
     * @param borrowSpeeds New borrow-side tokens speed for the corresponding market.
     */
    function _setRewardSpeeds(
        PToken[] memory pTokens,
        uint[] memory supplySpeeds,
        uint[] memory borrowSpeeds
    ) public {
        require(adminOrInitializing(), "only admin can set tokens speed");

        uint numTokens = pTokens.length;
        require(
            numTokens == supplySpeeds.length &&
                numTokens == borrowSpeeds.length,
            "Invalid input"
        );

        for (uint i = 0; i < numTokens; ++i) {
            setRewardSpeedInternal(pTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    /**
     * @notice Set tokens speed for a single contributor
     * @param contributor The contributor whose tokens speed to update
     * @param compSpeed New tokens speed for contributor
     */
    function _setContributorRewardSpeed(
        address contributor,
        uint compSpeed
    ) public {
        require(adminOrInitializing(), "only admin can set comp speed");

        // note that tokens speed could be set to 0 to halt liquidity rewards for a contributor
        updateContributorRewards(contributor);
        if (compSpeed == 0) {
            // release storage
            delete lastContributorBlock[contributor];
        } else {
            lastContributorBlock[contributor] = getBlockNumber();
        }
        compContributorSpeeds[contributor] = compSpeed;

        emit ContributorRewardSpeedUpdated(contributor, compSpeed);
    }

    /**
     * @notice Resets contributor speeds due to an error in emissions
     * @param contributors[] Contributors
     * @param tokens[] Tokens indexes to reset
     */
    function _resetContributorSpeeds(
        address[] memory contributors,
        PToken[] memory tokens
    ) public {
        require(adminOrInitializing(), "only admin can reset comp speeds");

        // reset the PToken market states
        for (uint i = 0; i < tokens.length; i++) {
            address pTokenAddy = address(tokens[i]);
            CompMarketState storage supplyState = compSupplyState[pTokenAddy];
            CompMarketState storage borrowState = compBorrowState[pTokenAddy];
            uint32 blockNumber = safe32(
                getBlockNumber(),
                "block number exceeds 32 bits"
            );
            // Reset market states
            supplyState.index = compInitialIndex;
            borrowState.index = compInitialIndex;
            supplyState.block = blockNumber;
            borrowState.block = blockNumber;

            // Reset emission speeds
            compSupplySpeeds[pTokenAddy] = 0;
            compBorrowSpeeds[pTokenAddy] = 0;

            // Reset contributer rewards storage values and any comp accrued due to error in emissions
            for (uint j = 0; j < contributors.length; j++) {
                // Reset the contributer rewards
                delete compSupplierIndex[pTokenAddy][contributors[j]];
                delete compBorrowerIndex[pTokenAddy][contributors[j]];
                delete compAccrued[contributors[j]];
            }
        }
    }

    /**
     * @notice Fixes withdrawals and deposits for any contributors left out of the initial reset
     * @param contributors[] Contributors
     * @param tokens[] Tokens indexes to reset
     */
    function _resetIndividualContributorSpeeds(
        address[] memory contributors,
        PToken[] memory tokens
    ) public {
        require(adminOrInitializing(), "only admin can reset comp speeds");

        // Loop through all tokens
        for (uint i = 0; i < tokens.length; i++) {
            for (uint j = 0; j < contributors.length; j++) {
                // Reset the contributer rewards
                address pTokenAddy = address(tokens[i]);
                delete compSupplierIndex[pTokenAddy][contributors[j]];
                delete compBorrowerIndex[pTokenAddy][contributors[j]];
                delete compAccrued[contributors[j]];
            }
        }
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (PToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Returns true if the given pToken market has been deprecated
     * @dev All borrows in a deprecated pToken market can be immediately liquidated
     * @param pToken The market to check if deprecated
     */
    function isDeprecated(PToken pToken) public view returns (bool) {
        return
            markets[address(pToken)].collateralFactorMantissa == 0 &&
            borrowGuardianPaused[address(pToken)] == true &&
            pToken.reserveFactorMantissa() == 1e18;
    }

    function getBlockNumber() public view virtual returns (uint) {
        return block.number;
    }

    /**
     * @notice Return the address of the tokens token
     * @return The address of tokens
     */
    function getTokenAddress() public view virtual returns (address) {
        return tokenAddress;
    }

    /**
     * @notice Set the address of the Token token
     * @param newAddress The new address of the Token token
     */
    function _setTokenAddress(address newAddress) public {
        require(msg.sender == admin, "only admin can set token address");
        tokenAddress = newAddress;
    }
}
