// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IStrategy.sol";
import "../interfaces/ISpaceMinter.sol";
import "../interfaces/ISpaceChef.sol";

import "./SpacePool.sol";
import "./PriceCalculator.sol";

contract Dashboard is Ownable {
    using SafeMath for uint256;

    PriceCalculator public constant priceCalculator = PriceCalculator(0x5D6086f8aae9DaEBAC5674E8F3b867D5743171D3);

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    // address public constant SPACE = 0xe486a69E432Fdc29622bF00315f6b34C99b45e80;
    address public constant SPACE = 0xe486a69E432Fdc29622bF00315f6b34C99b45e80;
    // address public constant BANANA = 0x603c7f932ED1fc6575303D8Fb018fDCBb0f39a95;
    address public constant BANANA = 0x603c7f932ED1fc6575303D8Fb018fDCBb0f39a95;
    // address public constant VaultBanana = 0x49F7a2B88D7B96053534Ad04bC57e71e3658137c;
    address public constant VaultBanana = 0xB8FDa49A709E9D00274053D9Ed34CCa1B4BB21f8;

    // ISpaceChef private constant spaceChef = ISpaceChef(0x720bFD03B3b507e0287190E727D6FeC88b4Bc3Ae);
    ISpaceChef private constant spaceChef = ISpaceChef(0x03Eb6A9E2C0e45c0657cf77B6497e8767c92c710);
    // SpacePool private constant spacePool = SpacePool(0x9E811bc0Fb0D42E461D909682be14e21a12A73Cf);
    SpacePool private constant spacePool = SpacePool(0xd79dc49Ed716832658ec28FE93dd733e0DFB8d58);

    mapping(address => PoolConstant.PoolTypes) public poolTypes;
    mapping(address => uint256) public apeswapPoolIds;
    mapping(address => bool) public perfExemptions;

    function setPoolType(address pool, PoolConstant.PoolTypes poolType) public onlyOwner {
        poolTypes[pool] = poolType;
    }

    function setApeswapPoolId(address pool, uint256 pid) public onlyOwner {
        apeswapPoolIds[pool] = pid;
    }

    function setPerfExemption(address pool, bool exemption) public onlyOwner {
        perfExemptions[pool] = exemption;
    }

    // ---- View Functions
    function poolTypeOf(address pool) public view returns (PoolConstant.PoolTypes) {
        return poolTypes[pool];
    }

    function calculateProfit(address pool, address account) public view returns (uint256 profit, uint256 profitInBNB) {
        PoolConstant.PoolTypes poolType = poolTypes[pool];
        profit = 0;
        profitInBNB = 0;

        if (poolType == PoolConstant.PoolTypes.SpaceStake) {
            // profit as bnb
            address rewardsToken = address(spacePool.SPACE());
            uint256 amount = spacePool.earned(account);
            (profit, ) = priceCalculator.valueOfAsset(rewardsToken, amount);
            profitInBNB = profit;
        } else if (poolType == PoolConstant.PoolTypes.Space) {
            // profit as space
            profit = spaceChef.pendingSpace(pool, account);
            (profitInBNB, ) = priceCalculator.valueOfAsset(SPACE, profit);
        } else if (poolType == PoolConstant.PoolTypes.BananaStake || poolType == PoolConstant.PoolTypes.FlipToFlip) {
            // profit as underlying
            IStrategy strategy = IStrategy(pool);
            profit = strategy.earned(account);
            (profitInBNB, ) = priceCalculator.valueOfAsset(strategy.stakingToken(), profit);
        } else if (poolType == PoolConstant.PoolTypes.FlipToBanana || poolType == PoolConstant.PoolTypes.SpaceBNB) {
            // profit as banana
            IStrategy strategy = IStrategy(pool);
            profit = strategy.earned(account).mul(IStrategy(strategy.rewardsToken()).priceShare()).div(1e18);
            (profitInBNB, ) = priceCalculator.valueOfAsset(BANANA, profit);
        }
    }

    function utilizationOfPool(address pool) public view returns (uint256 liquidity, uint256 utilized) {
        return (0, 0);
    }

    function profitOfPool(address pool, address account) public view returns (uint256 profit, uint256 space) {
        (uint256 profitCalculated, uint256 profitInBNB) = calculateProfit(pool, account);
        profit = profitCalculated;
        space = 0;

        if (!perfExemptions[pool]) {
            IStrategy strategy = IStrategy(pool);
            if (strategy.minter() != address(0)) {
                profit = profit.mul(70).div(100);
                space = ISpaceMinter(strategy.minter()).amountSpaceToMint(profitInBNB.mul(30).div(100));
            }

            if (strategy.spaceChef() != address(0)) {
                space = space.add(spaceChef.pendingSpace(pool, account));
            }
        }
    }

    function tvlOfPool(address pool) public view returns (uint256 tvl) {
        if (poolTypes[pool] == PoolConstant.PoolTypes.SpaceStake) {
            (, tvl) = priceCalculator.valueOfAsset(address(spacePool.SPACE()), spacePool.balance());
        } else {
            IStrategy strategy = IStrategy(pool);
            (, tvl) = priceCalculator.valueOfAsset(strategy.stakingToken(), strategy.balance());

            if (strategy.rewardsToken() == VaultBanana) {
                IStrategy rewardsToken = IStrategy(strategy.rewardsToken());
                uint256 rewardsInBanana = rewardsToken.balanceOf(pool).mul(rewardsToken.priceShare()).div(1e18);
                (, uint256 rewardsInUSD) = priceCalculator.valueOfAsset(address(BANANA), rewardsInBanana);
                tvl = tvl.add(rewardsInUSD);
            }
        }
    }

    function infoOfPool(address pool, address account) public view returns (PoolConstant.PoolInfoBSC memory) {
        PoolConstant.PoolInfoBSC memory poolInfo;

        IStrategy strategy = IStrategy(pool);
        (uint256 pBASE, uint256 pSPACE) = profitOfPool(pool, account);
        (uint256 liquidity, uint256 utilized) = utilizationOfPool(pool);

        poolInfo.pool = pool;
        poolInfo.balance = strategy.balanceOf(account);
        poolInfo.principal = strategy.principalOf(account);
        poolInfo.available = strategy.withdrawableBalanceOf(account);
        poolInfo.tvl = tvlOfPool(pool);
        poolInfo.utilized = utilized;
        poolInfo.liquidity = liquidity;
        poolInfo.pBASE = pBASE;
        poolInfo.pSPACE = pSPACE;

        PoolConstant.PoolTypes poolType = poolTypeOf(pool);
        if (poolType != PoolConstant.PoolTypes.SpaceStake && strategy.minter() != address(0)) {
            ISpaceMinter minter = ISpaceMinter(strategy.minter());
            poolInfo.depositedAt = strategy.depositedAt(account);
            poolInfo.feeDuration = minter.withdrawalFeeFreePeriod();
            poolInfo.feePercentage = minter.withdrawalFeeRate();
        }
        return poolInfo;
    }

    function poolsOf(address account, address[] memory pools) public view returns (PoolConstant.PoolInfoBSC[] memory) {
        PoolConstant.PoolInfoBSC[] memory results = new PoolConstant.PoolInfoBSC[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            results[i] = infoOfPool(pools[i], account);
        }
        return results;
    }

    function stakingTokenValueInUSD(address pool, address account) internal view returns (uint256 tokenInUSD) {
        PoolConstant.PoolTypes poolType = poolTypes[pool];

        address stakingToken;
        if (poolType == PoolConstant.PoolTypes.SpaceStake) {
            stakingToken = SPACE;
        } else {
            stakingToken = IStrategy(pool).stakingToken();
        }

        if (stakingToken == address(0)) return 0;
        (, tokenInUSD) = priceCalculator.valueOfAsset(stakingToken, IStrategy(pool).principalOf(account));
    }

    function portfolioOfPoolInUSD(address pool, address account) internal view returns (uint256) {
        uint256 tokenInUSD = stakingTokenValueInUSD(pool, account);
        (, uint256 profitInBNB) = calculateProfit(pool, account);
        uint256 profitInSPACE = 0;

        if (!perfExemptions[pool]) {
            IStrategy strategy = IStrategy(pool);
            if (strategy.minter() != address(0)) {
                profitInBNB = profitInBNB.mul(70).div(100);
                profitInSPACE = ISpaceMinter(strategy.minter()).amountSpaceToMint(profitInBNB.mul(30).div(100));
            }

            if (
                (poolTypes[pool] == PoolConstant.PoolTypes.Space ||
                    poolTypes[pool] == PoolConstant.PoolTypes.SpaceBNB ||
                    poolTypes[pool] == PoolConstant.PoolTypes.FlipToFlip) && strategy.spaceChef() != address(0)
            ) {
                profitInSPACE = profitInSPACE.add(spaceChef.pendingSpace(pool, account));
            }
        }

        (, uint256 profitBNBInUSD) = priceCalculator.valueOfAsset(WBNB, profitInBNB);
        (, uint256 profitSPACEInUSD) = priceCalculator.valueOfAsset(SPACE, profitInSPACE);
        return tokenInUSD.add(profitBNBInUSD).add(profitSPACEInUSD);
    }

    function portfolioOf(address account, address[] memory pools) public view returns (uint256 deposits) {
        deposits = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            deposits = deposits.add(portfolioOfPoolInUSD(pools[i], account));
        }
    }
}
