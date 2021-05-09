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
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../libraries/SafeBEP20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../libraries/RewardsDistributionRecipient.sol";
import "../libraries/Pausable.sol";
import "../interfaces/IStrategyHelper.sol";
import "../interfaces/IApeRouter02.sol";
import "../interfaces/ISpacePool.sol";

// @notice Fees Redistribution pool
contract SpacePool is ISpacePool, RewardsDistributionRecipient, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    IApeRouter02 private constant ROUTER = IApeRouter02(0xC0788A3aD43d79aa53B09c2EaCc313A787d1d607);
    // @notice SPACE TOKEN
    IBEP20 public immutable SPACE;
    // @notice SPACE_BNB Treasury -> WBNB Rewards
    IBEP20 public immutable REWARDS_TOKEN;

    // @notice Rewards distributed over 90 days
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 90 days;

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 private totalDeposited;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    mapping(address => uint256) private _balances;

    // @notice delegate staking
    mapping(address => bool) private _stakePermission;

    // @notice contract with utils functions
    IStrategyHelper public helper;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier canStakeTo() {
        require(_stakePermission[msg.sender], "auth");
        _;
    }

    constructor(
        address _helper,
        address _STAKING_TOKEN,
        address _REWARDS_TOKEN
    ) public {
        rewardsDistribution = msg.sender;
        _stakePermission[msg.sender] = true;

        REWARDS_TOKEN = IBEP20(_REWARDS_TOKEN);
        SPACE = IBEP20(_STAKING_TOKEN);

        helper = IStrategyHelper(_helper);

        IBEP20(_REWARDS_TOKEN).safeApprove(address(ROUTER), 0);
        IBEP20(_REWARDS_TOKEN).safeApprove(address(ROUTER), uint256(~0));

        IBEP20(_STAKING_TOKEN).safeApprove(address(ROUTER), 0);
        IBEP20(_STAKING_TOKEN).safeApprove(address(ROUTER), uint256(~0));
    }

    function deposit(uint256 amount) public override {
        _deposit(amount, msg.sender);
    }

    function depositAll() external override {
        deposit(SPACE.balanceOf(msg.sender));
    }

    function _deposit(uint256 amount, address to) private nonReentrant notPaused updateReward(to) {
        require(amount > 0, "amount");
        totalDeposited = totalDeposited.add(amount);
        _balances[to] = _balances[to].add(amount);
        SPACE.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(to, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "amount");
        totalDeposited = totalDeposited.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        SPACE.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function withdrawAll() external override {
        uint256 _withdraw = _balances[msg.sender];
        if (_withdraw > 0) {
            withdraw(_withdraw);
        }
        getReward();
    }

    function getReward() public override nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            reward = _flipToWBNB(reward);
            IBEP20(ROUTER.WETH()).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function _flipToWBNB(uint256 amount) private returns (uint256 reward) {
        address wbnb = ROUTER.WETH();
        (uint256 rewardSpace, ) = ROUTER.removeLiquidity(address(SPACE), wbnb, amount, 0, 0, address(this), block.timestamp);
        address[] memory path = new address[](2);
        path[0] = address(SPACE);
        path[1] = wbnb;
        require(rewardSpace > 0, "SpacePool: _flipToWBNB no reward");
        ROUTER.swapExactTokensForTokens(rewardSpace, 0, path, address(this), block.timestamp);
        reward = IBEP20(wbnb).balanceOf(address(this));
    }

    function setHelper(IStrategyHelper _helper) external onlyOwner {
        require(address(_helper) != address(0), "SpacePool: setHelper zero address");
        helper = _helper;
    }

    function setStakePermission(address _address, bool permission) external onlyOwner {
        _stakePermission[_address] = permission;
    }

    function stakeTo(uint256 amount, address _to) external canStakeTo {
        _deposit(amount, _to);
    }

    function notifyRewardAmount(uint256 reward) external override onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        uint256 _balance = REWARDS_TOKEN.balanceOf(address(this));
        require(rewardRate <= _balance.div(rewardsDuration), "reward");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(periodFinish == 0 || block.timestamp > periodFinish, "period");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    function info(address account) external view override returns (UserInfo memory) {
        UserInfo memory userInfo;

        userInfo.balance = _balances[account];
        userInfo.principal = _balances[account];
        userInfo.available = _balances[account];

        Profit memory profit;
        (uint256 usd, uint256 space, uint256 bnb) = profitOf(account);
        profit.usd = usd;
        profit.space = space;
        profit.bnb = bnb;
        userInfo.profit = profit;

        userInfo.poolTVL = tvl();

        APY memory poolAPY;
        (usd, space, bnb) = apy();
        poolAPY.usd = usd;
        poolAPY.space = space;
        poolAPY.bnb = bnb;
        userInfo.poolAPY = poolAPY;

        return userInfo;
    }

    function profitOf(address account)
        public
        view
        override
        returns (
            uint256 _usd,
            uint256 _space,
            uint256 _bnb
        )
    {
        _usd = 0;
        _space = 0;
        _bnb = helper.tvlInBNB(address(REWARDS_TOKEN), earned(account));
    }

    function apy()
        public
        view
        override
        returns (
            uint256 _usd,
            uint256 _space,
            uint256 _bnb
        )
    {
        uint256 tokenDecimals = 1e18;
        uint256 __totalSupply = totalDeposited;
        if (__totalSupply == 0) {
            __totalSupply = tokenDecimals;
        }

        uint256 rewardPerTokenPerSecond = rewardRate.mul(tokenDecimals).div(__totalSupply);

        uint256 spacePrice = helper.tokenPriceInBNB(address(SPACE));
        uint256 lpPrice = helper.tvlInBNB(address(REWARDS_TOKEN), 1e18);

        _usd = 0;
        _space = 0;
        _bnb = 0;
        if (lpPrice > 0 && spacePrice > 0) {
            _bnb = rewardPerTokenPerSecond.mul(365 days).mul(lpPrice).div(spacePrice);
        }
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalDeposited == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored.add(lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(totalDeposited));
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function tvl() public view override returns (uint256) {
        uint256 price = helper.tokenPriceInBNB(address(SPACE));
        return price > 0 ? totalDeposited.mul(price).div(1e18) : 0;
    }

    function earned(address account) public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    function totalSupply() external view returns (uint256) {
        return totalDeposited;
    }

    function balance() external view override returns (uint256) {
        return totalDeposited;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function principalOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    // @notice Emergency only
    function recoverBEP20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(SPACE) && tokenAddress != address(REWARDS_TOKEN), "tokenAddress");
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }
}
