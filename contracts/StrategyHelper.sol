// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;

import "../interfaces/IBEP20.sol";
import "../libraries/BEP20.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";

import "../interfaces/IApeFactory.sol";
import "../interfaces/IApePair.sol";
import "../interfaces/IMasterApe.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IStrategyHelper.sol";

contract StrategyHelper is IStrategyHelper {
    using SafeMath for uint256;
    address private constant BANANA_BNB_LP = 0xF65C1C0478eFDe3c19b49EcBE7ACc57BB6B1D713;
    address private constant BNB_BUSD_POOL = 0x51e6D27FA57373d8d4C256231241053a70Cb1d93;

    IBEP20 private constant WBNB = IBEP20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IBEP20 private constant BANANA = IBEP20(0x603c7f932ED1fc6575303D8Fb018fDCBb0f39a95);
    IBEP20 private constant BUSD = IBEP20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    IMasterApe private constant APE_MASTER_CHEF = IMasterApe(0x5c8D727b265DBAfaba67E050f2f739cAeEB4A6F9);
    IApeFactory private constant factory = IApeFactory(0x0841BD0B734E4F5853f0dD8d7Ea041c241fb0Da6);

    function tokenPriceInBNB(address _token) public view override returns (uint256) {
        address pair = factory.getPair(_token, address(WBNB));
        uint256 decimal = uint256(BEP20(_token).decimals());
        return WBNB.balanceOf(pair).mul(10**decimal).div(IBEP20(_token).balanceOf(pair));
    }

    function bananaPriceInBNB() public view override returns (uint256) {
        return WBNB.balanceOf(BANANA_BNB_LP).mul(1e18).div(BANANA.balanceOf(BANANA_BNB_LP));
    }

    function bnbPriceInUSD() public view override returns (uint256) {
        return BUSD.balanceOf(BNB_BUSD_POOL).mul(1e18).div(WBNB.balanceOf(BNB_BUSD_POOL));
    }

    function bananaPerYearOfPool(uint256 pid) public view returns (uint256) {
        (, uint256 allocPoint, , ) = APE_MASTER_CHEF.poolInfo(pid);
        return APE_MASTER_CHEF.cakePerBlock().mul(blockPerYear()).mul(allocPoint).div(APE_MASTER_CHEF.totalAllocPoint());
    }

    function blockPerYear() public pure returns (uint256) {
        return 10512000;
    }

    function profitOf(
        ISpaceMinter minter,
        address flip,
        uint256 amount
    )
        external
        view
        override
        returns (
            uint256 _usd,
            uint256 _space,
            uint256 _bnb
        )
    {
        _usd = tvl(flip, amount);
        if (address(minter) == address(0)) {
            _space = 0;
        } else {
            uint256 performanceFee = minter.performanceFee(_usd);
            _usd = _usd.sub(performanceFee);
            uint256 bnbAmount = performanceFee.mul(1e18).div(bnbPriceInUSD());
            _space = minter.amountSpaceToMint(bnbAmount);
        }
        _bnb = 0;
    }

    function _apy(uint256 pid) private view returns (uint256) {
        (address token, , , ) = APE_MASTER_CHEF.poolInfo(pid);
        uint256 poolSize = tvl(token, IBEP20(token).balanceOf(address(APE_MASTER_CHEF))).mul(1e18).div(bnbPriceInUSD());
        return bananaPriceInBNB().mul(bananaPerYearOfPool(pid)).div(poolSize);
    }

    function apy(ISpaceMinter, uint256 pid)
        public
        view
        override
        returns (
            uint256 _usd,
            uint256 _space,
            uint256 _bnb
        )
    {
        _usd = compoundingAPY(pid, 1 days);
        _space = 0;
        _bnb = 0;
    }

    function tvl(address _flip, uint256 amount) public view override returns (uint256) {
        return tvlInBNB(_flip, amount).mul(bnbPriceInUSD()).div(1e18);
    }

    function tvlInBNB(address _flip, uint256 amount) public view override returns (uint256) {
        if (_flip == address(BANANA)) {
            return bananaPriceInBNB().mul(amount).div(1e18);
        }
        address _token0 = IApePair(_flip).token0();
        address _token1 = IApePair(_flip).token1();
        if (_token0 == address(WBNB) || _token1 == address(WBNB)) {
            uint256 bnb = WBNB.balanceOf(address(_flip)).mul(amount).div(IBEP20(_flip).totalSupply());
            return bnb.mul(2);
        }

        uint256 balanceToken0 = IBEP20(_token0).balanceOf(_flip);
        uint256 price = tokenPriceInBNB(_token0);
        return balanceToken0.mul(price).mul(2).div(1e18);
    }

    function compoundingAPY(uint256 pid, uint256 compoundUnit) public view override returns (uint256) {
        uint256 __apy = _apy(pid);
        uint256 compoundTimes = 365 days / compoundUnit;
        uint256 unitAPY = 1e18 + (__apy.div(compoundTimes));
        uint256 result = 1e18;

        for (uint256 i = 0; i < compoundTimes; i++) {
            result = (result.mul(unitAPY)).div(1e18);
        }

        return result.sub(1e18);
    }
}
