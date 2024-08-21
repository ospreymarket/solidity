// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import './PriceOracle.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import './External/SafeMath.sol';
import './PErc20.sol';
import './External/Supra.sol';
import './External/FullMath.sol';

contract SupraOracle is Ownable, PriceOracle {
    using SafeMath for uint32;
    using SafeMath for uint;
    address public oracleAddress;
    uint256 public priceInvalidAfterSeconds = 43200 * 1000;
    mapping (address => uint256) public addressToPairId;

    error OraclePriceLessThanZero();
    error OraclePriceInvalid();

    constructor() Ownable(msg.sender) {}

    // Push Oracle = 0x6Cd59830AAD978446e6cc7f6cc173aF7656Fb917
    function setOracleAddress (address _oracleAddress) external onlyOwner {
        oracleAddress = _oracleAddress;
    }

    function setPriceInvalidAfterSeconds (uint256 _priceInvalidAfterSeconds) external onlyOwner {
        priceInvalidAfterSeconds = _priceInvalidAfterSeconds;
    }

    function setPairIds (address[] calldata underlyingAssets, uint256[] calldata pairIds) external onlyOwner {
        require(underlyingAssets.length == pairIds.length, "Pairs must be the same length");
        for (uint i = 0; i < underlyingAssets.length; i++) {
            addressToPairId[underlyingAssets[i]] = pairIds[i];
        }
    }

    function getUnderlyingPrice(PToken pToken) public view override returns (uint) {
        address asset = _getUnderlyingAddress(pToken);
        // Get price feed
        ISupraSValueFeed supraFeed = ISupraSValueFeed(oracleAddress);
        ISupraSValueFeed.priceFeed memory price = supraFeed.getSvalue(addressToPairId[asset]);

        // Check oracle price time is valid
        if ((block.timestamp * 1000) - price.time > priceInvalidAfterSeconds) {
            revert OraclePriceInvalid();
        }

        uint32 expToUse = uint32(36 - price.decimals);
        
        // Get underlying decimals
        uint underlyingDecimals = asset == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE ? 18 : PErc20(asset).decimals();

        return FullMath.mulDiv(
            10 ** expToUse,
            uint256(int256(price.price)),
            10 ** underlyingDecimals
        );
    }

    function _getUnderlyingAddress(PToken pToken) internal view returns (address) {
        address asset;
        if (compareStrings(pToken.symbol(), "pETH")) {
            asset = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        } else {
            asset = PErc20(address(pToken)).underlying();
        }
        return asset;
    }

    function compareStrings(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) ==
            keccak256(abi.encodePacked((b))));
    }
}