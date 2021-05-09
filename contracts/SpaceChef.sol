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

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../libraries/SafeBEP20.sol";

import "../interfaces/IBEP20.sol";
import "../interfaces/ISpaceMinter.sol";
import "../interfaces/ISpaceChef.sol";
import "../interfaces/IStrategy.sol";
import "./SpaceToken.sol";

contract SpaceChef is ISpaceChef, Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    SpaceToken public immutable SPACE;
    // @notice Can't be modified
    ISpaceMinter public MINTER;

    address[] private _vaultList;

    mapping(address => VaultInfo) vaults;
    mapping(address => mapping(address => UserInfo)) vaultUsers;

    uint256 public startBlock;
    uint256 public override spacePerBlock;
    uint256 public override totalAllocPoint;

    event NotifyDeposited(address indexed user, address indexed vault, uint256 amount);
    event NotifyWithdrawn(address indexed user, address indexed vault, uint256 amount);
    event SpaceRewardPaid(address indexed user, address indexed vault, uint256 amount);
    event LogVaultAddition(address indexed vault, uint256 allocPoint, address indexed token);
    event LogVaultUpdated(address indexed vault, uint256 allocPoint);

    modifier onlyVaults {
        require(vaults[msg.sender].token != address(0), "SpaceChef: caller is not on the vault");
        _;
    }

    modifier updateRewards(address vault) {
        VaultInfo storage vaultInfo = vaults[vault];
        if (block.number > vaultInfo.lastRewardBlock) {
            uint256 tokenSupply = tokenSupplyOf(vault);
            if (tokenSupply > 0) {
                uint256 multiplier = timeMultiplier(vaultInfo.lastRewardBlock, block.number);
                uint256 rewards = multiplier.mul(spacePerBlock).mul(vaultInfo.allocPoint).div(totalAllocPoint);
                vaultInfo.accSpacePerShare = vaultInfo.accSpacePerShare.add(rewards.mul(1e12).div(tokenSupply));
            }
            vaultInfo.lastRewardBlock = block.number;
        }
        _;
    }

    constructor(
        uint256 _startBlock,
        uint256 _spacePerBlock,
        address _SPACE
    ) public {
        SPACE = SpaceToken(_SPACE);

        startBlock = _startBlock;
        spacePerBlock = _spacePerBlock;
    }

    function timeMultiplier(uint256 from, uint256 to) public pure returns (uint256) {
        return to.sub(from);
    }

    function tokenSupplyOf(address vault) public view returns (uint256) {
        return IStrategy(vault).totalSupply();
    }

    function vaultInfoOf(address vault) external view override returns (VaultInfo memory) {
        return vaults[vault];
    }

    function vaultUserInfoOf(address vault, address user) external view override returns (UserInfo memory) {
        return vaultUsers[vault][user];
    }

    function pendingSpace(address vault, address user) public view override returns (uint256) {
        UserInfo storage userInfo = vaultUsers[vault][user];
        VaultInfo storage vaultInfo = vaults[vault];

        uint256 accSpacePerShare = vaultInfo.accSpacePerShare;
        uint256 tokenSupply = tokenSupplyOf(vault);
        if (block.number > vaultInfo.lastRewardBlock && tokenSupply > 0) {
            uint256 multiplier = timeMultiplier(vaultInfo.lastRewardBlock, block.number);
            uint256 spaceRewards = multiplier.mul(spacePerBlock).mul(vaultInfo.allocPoint).div(totalAllocPoint);
            accSpacePerShare = accSpacePerShare.add(spaceRewards.mul(1e12).div(tokenSupply));
        }
        return userInfo.pending.add(userInfo.balance.mul(accSpacePerShare).div(1e12).sub(userInfo.rewardPaid));
    }

    // Only Owner
    function addVault(
        address vault,
        address token,
        uint256 allocPoint,
        bool update
    ) public onlyOwner {
        require(address(token) != address(0), "SpaceChef: wrong token address");
        require(vaults[vault].token == address(0), "SpaceChef: vault is already set");
        if (update) {
            massUpdateVaultsRewards();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        vaults[vault] = VaultInfo(token, allocPoint, lastRewardBlock, 0);
        _vaultList.push(vault);

        emit LogVaultAddition(vault, allocPoint, token);
    }

    function updateVault(
        address vault,
        uint256 allocPoint,
        bool update
    ) public onlyOwner {
        require(vaults[vault].token != address(0), "SpaceChef: vault must be set");
        if (update) {
            massUpdateVaultsRewards();
        }

        uint256 lastAllocPoint = vaults[vault].allocPoint;
        if (lastAllocPoint != allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(lastAllocPoint).add(allocPoint);
        }
        vaults[vault].allocPoint = allocPoint;
        emit LogVaultUpdated(vault, allocPoint);
    }

    function updateEmissionPerBlock(uint256 _spacePerBlock, bool update) external onlyOwner {
        massUpdateVaultsRewards();
        spacePerBlock = _spacePerBlock;
    }

    function initializeMinter(address minter) external onlyOwner {
        require(address(MINTER) == address(0), "SpaceChef: MINTER already set");
        MINTER = ISpaceMinter(minter);
    }

    function notifyDeposited(address user, uint256 amount) external override onlyVaults updateRewards(msg.sender) {
        UserInfo storage userInfo = vaultUsers[msg.sender][user];
        VaultInfo storage vaultInfo = vaults[msg.sender];

        uint256 pending = userInfo.balance.mul(vaultInfo.accSpacePerShare).div(1e12).sub(userInfo.rewardPaid);
        userInfo.pending = userInfo.pending.add(pending);
        userInfo.balance = userInfo.balance.add(amount);
        userInfo.rewardPaid = userInfo.balance.mul(vaultInfo.accSpacePerShare).div(1e12);
        emit NotifyDeposited(user, msg.sender, amount);
    }

    function notifyWithdrawn(address user, uint256 amount) external override onlyVaults updateRewards(msg.sender) {
        UserInfo storage userInfo = vaultUsers[msg.sender][user];
        VaultInfo storage vaultInfo = vaults[msg.sender];

        uint256 pending = userInfo.balance.mul(vaultInfo.accSpacePerShare).div(1e12).sub(userInfo.rewardPaid);
        userInfo.pending = userInfo.pending.add(pending);
        userInfo.balance = userInfo.balance.sub(amount);
        userInfo.rewardPaid = userInfo.balance.mul(vaultInfo.accSpacePerShare).div(1e12);
        emit NotifyWithdrawn(user, msg.sender, amount);
    }

    function safeSpaceTransfer(address user) external override onlyVaults updateRewards(msg.sender) returns (uint256) {
        UserInfo storage userInfo = vaultUsers[msg.sender][user];
        VaultInfo storage vaultInfo = vaults[msg.sender];

        uint256 pending = userInfo.balance.mul(vaultInfo.accSpacePerShare).div(1e12).sub(userInfo.rewardPaid);
        uint256 amount = userInfo.pending.add(pending);
        userInfo.pending = 0;
        userInfo.rewardPaid = userInfo.balance.mul(vaultInfo.accSpacePerShare).div(1e12);

        MINTER.mint(user, amount);
        // MINTER.safeSpaceTransfer(user, amount);
        emit SpaceRewardPaid(user, msg.sender, amount);
        return amount;
    }

    function massUpdateVaultsRewards() public {
        for (uint256 idx = 0; idx < _vaultList.length; idx++) {
            if (_vaultList[idx] != address(0) && vaults[_vaultList[idx]].token != address(0)) {
                updateRewardsOf(_vaultList[idx]);
            }
        }
    }

    function updateRewardsOf(address vault) public updateRewards(vault) {}

    // Emergency only
    function recoverToken(address _token, uint256 amount) external virtual onlyOwner {
        require(_token != address(SPACE), "SpaceChef: cannot recover SPACE token");
        IBEP20(_token).safeTransfer(owner(), amount);
    }
}
