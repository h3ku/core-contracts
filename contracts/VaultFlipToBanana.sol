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
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../libraries/RewardsDistributionRecipient.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IMasterApe.sol";
import "../interfaces/ISpaceMinter.sol";
import "./VaultController.sol";

import {PoolConstant} from "../libraries/PoolConstant.sol";

contract VaultFlipToBanana is VaultController, IStrategy, RewardsDistributionRecipient, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    address private constant BANANA = 0x603c7f932ED1fc6575303D8Fb018fDCBb0f39a95;
    IMasterApe private constant APE_MASTER_CHEF = IMasterApe(0x5c8D727b265DBAfaba67E050f2f739cAeEB4A6F9);
    PoolConstant.PoolTypes public constant override poolType = PoolConstant.PoolTypes.FlipToBanana;

    IStrategy private _rewardsToken;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardsDuration;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    uint256 public override pid;
    mapping(address => uint256) private _depositedAt;

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    event RewardAdded(uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);

    constructor(
        uint256 _pid,
        IBEP20 token,
        address _minter,
        address _vaultBanana,
        address _spaceToken
    ) public VaultController(token, _spaceToken) {
        _stakingToken.safeApprove(address(APE_MASTER_CHEF), uint256(~0));
        pid = _pid;

        rewardsDuration = 24 hours;

        rewardsDistribution = msg.sender;
        setMinter(_minter);
        setRewardsToken(_vaultBanana);
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balance() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function sharesOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function principalOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function depositedAt(address account) external view override returns (uint256) {
        return _depositedAt[account];
    }

    function withdrawableBalanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function rewardsToken() external view override returns (address) {
        return address(_rewardsToken);
    }

    function priceShare() external view override returns (uint256) {
        return 1e18;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored.add(lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply));
    }

    function earned(address account) public view override returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    function _deposit(uint256 amount, address _to) private nonReentrant notPaused updateReward(_to) {
        require(amount > 0, "VaultFlipToBanana: amount must be greater than zero");
        _totalSupply = _totalSupply.add(amount);
        _balances[_to] = _balances[_to].add(amount);
        _depositedAt[_to] = block.timestamp;
        _stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        APE_MASTER_CHEF.deposit(pid, amount);
        emit Deposited(_to, amount);

        _harvest();
    }

    function deposit(uint256 amount) public override {
        _deposit(amount, msg.sender);
    }

    function depositAll() external override {
        deposit(_stakingToken.balanceOf(msg.sender));
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "VaultFlipToBanana: amount must be greater than zero");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        APE_MASTER_CHEF.withdraw(pid, amount);
        uint256 withdrawalFee;
        if (canMint()) {
            uint256 depositTimestamp = _depositedAt[msg.sender];
            withdrawalFee = _minter.withdrawalFee(amount, depositTimestamp);
            if (withdrawalFee > 0) {
                uint256 performanceFee = withdrawalFee.div(100);
                _minter.mintFor(address(_stakingToken), withdrawalFee.sub(performanceFee), performanceFee, msg.sender, depositTimestamp);
                amount = amount.sub(withdrawalFee);
            }
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);

        _harvest();
    }

    function withdrawAll() external override {
        uint256 _withdraw = withdrawableBalanceOf(msg.sender);
        if (_withdraw > 0) {
            withdraw(_withdraw);
        }
        getReward();
    }

    function getReward() public override nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            uint256 before = IBEP20(BANANA).balanceOf(address(this));
            _rewardsToken.withdraw(reward);
            uint256 bananaBalance = IBEP20(BANANA).balanceOf(address(this)).sub(before);
            uint256 performanceFee;

            if (canMint()) {
                performanceFee = _minter.performanceFee(bananaBalance);
                _minter.mintFor(BANANA, 0, performanceFee, msg.sender, _depositedAt[msg.sender]);
            }

            IBEP20(BANANA).safeTransfer(msg.sender, bananaBalance.sub(performanceFee));
            emit ProfitPaid(msg.sender, bananaBalance, performanceFee);
        }
    }

    function harvest() public override {
        APE_MASTER_CHEF.withdraw(pid, 0);
        _harvest();
    }

    function _harvest() private {
        uint256 bananaAmount = IBEP20(BANANA).balanceOf(address(this));
        uint256 _before = _rewardsToken.sharesOf(address(this));
        _rewardsToken.deposit(bananaAmount);
        uint256 amount = _rewardsToken.sharesOf(address(this)).sub(_before);
        if (amount > 0) {
            _notifyRewardAmount(amount);
            emit Harvested(amount);
        }
    }

    function setMinter(address newMinter) public override onlyOwner {
        VaultController.setMinter(newMinter);
        if (newMinter != address(0)) {
            IBEP20(BANANA).safeApprove(newMinter, 0);
            IBEP20(BANANA).safeApprove(newMinter, uint256(~0));
        }
    }

    function setRewardsToken(address newRewardsToken) public onlyOwner {
        require(address(_rewardsToken) == address(0), "VaultFlipToBanana: rewards token already set");

        _rewardsToken = IStrategy(newRewardsToken);
        IBEP20(BANANA).safeApprove(newRewardsToken, 0);
        IBEP20(BANANA).safeApprove(newRewardsToken, uint256(~0));
    }

    function notifyRewardAmount(uint256 reward) public override onlyRewardsDistribution {
        _notifyRewardAmount(reward);
    }

    function _notifyRewardAmount(uint256 reward) private updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        uint256 _balance = _rewardsToken.sharesOf(address(this));
        require(rewardRate <= _balance.div(rewardsDuration), "VaultFlipToBanana: reward rate must be in the right range");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(
            periodFinish == 0 || block.timestamp > periodFinish,
            "VaultFlipToBanana: reward duration can only be updated after the period ends"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    function recoverToken(address tokenAddress, uint256 tokenAmount) external override onlyOwner {
        require(
            tokenAddress != address(_stakingToken) && tokenAddress != _rewardsToken.stakingToken(),
            "VaultFlipToBanana: cannot recover underlying token"
        );
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }
}
