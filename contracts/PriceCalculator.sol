// SPDX-License-Identifier: MIT
// Version @2021-05
/*
 █████╗ ██████╗ ███████╗██████╗  ██████╗  ██████╗██╗  ██╗███████╗████████╗
██╔══██╗██╔══██╗██╔════╝██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝██╔════╝╚══██╔══╝
███████║██████╔╝█████╗  ██████╔╝██║   ██║██║     █████╔╝ █████╗     ██║   
██╔══██║██╔═══╝ ██╔══╝  ██╔══██╗██║   ██║██║     ██╔═██╗ ██╔══╝     ██║   
██║  ██║██║     ███████╗██║  ██║╚██████╔╝╚██████╗██║  ██╗███████╗   ██║   
╚═╝  ╚═╝╚═╝     ╚══════╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝  
 */

pragma solidity >=0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../libraries/HomoraMath.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IBEP20.sol";
import "../interfaces/IApePair.sol";
import "../interfaces/IApeFactory.sol";
import "../interfaces/AggregatorV3Interface.sol";
import "../interfaces/IPriceCalculator.sol";

contract PriceCalculator is IPriceCalculator, Ownable {
    using SafeMath for uint256;
    using HomoraMath for uint256;

    address public immutable SPACE;
    address public immutable SPACE_BNB;

    IPriceOracle public oracle;

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant BANANA = 0x603c7f932ED1fc6575303D8Fb018fDCBb0f39a95;
    address public constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    IApeFactory private constant factory = IApeFactory(0x0841BD0B734E4F5853f0dD8d7Ea041c241fb0Da6);
    AggregatorV3Interface private constant bnbPriceFeed = AggregatorV3Interface(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);

    mapping(address => address) private pairTokens;
    mapping(address => address) private tokenFeeds;
    mapping(address => bool) private oracleFeeds;

    constructor(
        address _SPACE_TOKEN,
        address _SPACE_BNB,
        IPriceOracle _oracle
    ) public {
        oracle = _oracle;
        SPACE = _SPACE_TOKEN;
        SPACE_BNB = _SPACE_BNB;
    }

    // Add Pair to asset to be able to use valueOfAsset
    function setPairToken(address asset, address pairToken) public onlyOwner {
        pairTokens[asset] = pairToken;
    }

    function setTokenFeed(address asset, address feed) public onlyOwner {
        tokenFeeds[asset] = feed;
    }

    function setOracleFeeds(address asset, bool available) public onlyOwner {
        oracleFeeds[asset] = available;
    }

    // Price of BNB via Chainlink
    function priceOfBNB() public view returns (uint256) {
        (, int256 price, , , ) = bnbPriceFeed.latestRoundData();
        return uint256(price).mul(1e10);
    }

    // Price of Banana using PriceOracle
    function priceOfBanana() public view returns (uint256) {
        require(oracleFeeds[BANANA], "PriceFeed: Banana not available in Oracle");
        (uint256 priceInBnb, ) = oracle.getPrice(BANANA, WBNB);
        uint256 valueInUSD = priceInBnb.mul(priceOfBNB()).div(1e18);
        return valueInUSD;
    }

    function priceOfSpace() public view returns (uint256) {
        (, uint256 spacePriceInUSD) = valueOfAsset(SPACE, 1e18);
        return spacePriceInUSD;
    }

    function pricesInUSD(address[] memory assets) public view override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            (, uint256 valueInUSD) = valueOfAsset(assets[i], 1e18);
            prices[i] = valueInUSD;
        }
        return prices;
    }

    function _oracleValueOf(address asset, uint256 amount) private view returns (uint256 valueInBNB, uint256 valueInUSD) {
        require(oracleFeeds[asset], "PriceFeed: asset not available in Oracle");

        if (tokenFeeds[asset] != address(0)) {
            (, int256 price, , , ) = AggregatorV3Interface(tokenFeeds[asset]).latestRoundData();
            valueInUSD = uint256(price).mul(1e10).mul(amount).div(1e18);
            valueInBNB = valueInUSD.mul(1e18).div(priceOfBNB());
        } else {
            (uint256 assetPriceInBnb, ) = oracle.getPrice(asset, WBNB);
            valueInBNB = assetPriceInBnb.mul(amount).div(1e18);
            valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
        }
    }

    function valueOfAsset(address asset, uint256 amount) public view override returns (uint256 valueInBNB, uint256 valueInUSD) {
        if (asset == address(0) || asset == WBNB) {
            return _oracleValueOf(WBNB, amount);
        } else if (asset == SPACE || asset == SPACE_BNB) {
            return _valueOfAsset(asset, amount);
        } else if (keccak256(abi.encodePacked(IApePair(asset).symbol())) == keccak256("APE-LP")) {
            return _getPairPrice(asset, amount);
        } else {
            return _oracleValueOf(asset, amount);
        }
    }

    function _getPairPrice(address pair, uint256 amount) private view returns (uint256 valueInBNB, uint256 valueInUSD) {
        address token0 = IApePair(pair).token0();
        address token1 = IApePair(pair).token1();
        uint256 totalSupply = IApePair(pair).totalSupply();
        (uint256 r0, uint256 r1, ) = IApePair(pair).getReserves();
        uint256 sqrtK = HomoraMath.sqrt(r0.mul(r1)).fdiv(totalSupply);
        (uint256 px0, ) = _oracleValueOf(token0, 1e18);
        (uint256 px1, ) = _oracleValueOf(token1, 1e18);
        uint256 fairPriceInBNB = sqrtK.mul(2).mul(HomoraMath.sqrt(px0)).div(2**56).mul(HomoraMath.sqrt(px1)).div(2**56);
        valueInBNB = fairPriceInBNB.mul(amount).div(1e18);
        valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
    }

    // Need to add Pair Token before using it
    function _valueOfAsset(address asset, uint256 amount) public view returns (uint256 valueInBNB, uint256 valueInUSD) {
        if (asset == address(0) || asset == WBNB) {
            valueInBNB = amount;
            valueInUSD = amount.mul(priceOfBNB()).div(1e18);
        } else if (keccak256(abi.encodePacked(IApePair(asset).symbol())) == keccak256("APE-LP")) {
            if (IApePair(asset).token0() == WBNB || IApePair(asset).token1() == WBNB) {
                valueInBNB = amount.mul(IBEP20(WBNB).balanceOf(address(asset))).mul(2).div(IApePair(asset).totalSupply());
                valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
            } else {
                uint256 balanceToken0 = IBEP20(IApePair(asset).token0()).balanceOf(asset);
                (uint256 token0PriceInBNB, ) = valueOfAsset(IApePair(asset).token0(), 1e18);

                valueInBNB = amount.mul(balanceToken0).mul(2).mul(token0PriceInBNB).div(1e18).div(IApePair(asset).totalSupply());
                valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
            }
        } else {
            address pairToken = pairTokens[asset] == address(0) ? WBNB : pairTokens[asset];
            address pair = factory.getPair(asset, pairToken);
            valueInBNB = IBEP20(pairToken).balanceOf(pair).mul(amount).div(IBEP20(asset).balanceOf(pair));
            if (pairToken != WBNB) {
                (uint256 pairValueInBNB, ) = valueOfAsset(pairToken, 1e18);
                valueInBNB = valueInBNB.mul(pairValueInBNB).div(1e18);
            }
            valueInUSD = valueInBNB.mul(priceOfBNB()).div(1e18);
        }
    }

    function updateOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "PriceCalculator: updateOracle wrong address");
        require(newOracle != address(oracle), "PriceCalculator: updateOracle address already set");
        oracle = IPriceOracle(newOracle);
    }
}
