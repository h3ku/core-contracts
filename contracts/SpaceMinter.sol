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
import "@openzeppelin/contracts/utils/Address.sol";

import "../libraries/BEP20.sol";
import "../libraries/SafeBEP20.sol";
import "../interfaces/ISpaceMinter.sol";
import "../interfaces/IStakingRewards.sol";
import "./PriceCalculator.sol";
import "./SpaceToken.sol";
import "./Zap.sol";

contract SpaceMinter is ISpaceMinter, Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;
    using Address for address;

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    SpaceToken public immutable SPACE;

    // @notice dev address for space allocation
    address public immutable DEPLOYER;
    address public immutable SPACE_BNB_PAIR;
    address public immutable SPACE_POOL;
    // @notice masterchef
    address public immutable SPACE_CHEF;

    Zap public zap;
    // @notice owner of the contract when set up
    address public governance;
    // @notice used to calculate value of assets to determine number of space minted.
    PriceCalculator public priceCalculator;

    // @notice lists of vaults/contracts allowed to mint space.
    mapping(address => bool) private _minters;

    uint256 public constant DENOMINATOR = 10000;
    uint256 public constant MAX_WITHDRAWAL_FEE = 500; // 5%
    uint256 public constant MAX_PERFORMANCE_FEE = 5000; // 50%

    uint256 public performanceFeeRate;
    uint256 public override withdrawalFeeFreePeriod;
    uint256 public override withdrawalFeeRate;

    // @notice Space amount to mint per BNB
    uint256 public override amountToMintPerProfit;

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "SpaceMinter: caller is not allowed dest mint");
        _;
    }

    modifier onlySpaceChef {
        require(msg.sender == SPACE_CHEF, "SpaceMinter: caller not the space chef");
        _;
    }

    // @notice fallback
    receive() external payable {}

    constructor(
        address _SPACE,
        address _SPACE_CHEF,
        address _SPACE_POOL,
        address _PAIR,
        address payable _zap,
        address _priceCalculator
    ) public {
        DEPLOYER = msg.sender;

        SPACE = SpaceToken(_SPACE);
        SPACE_CHEF = _SPACE_CHEF;
        SPACE_POOL = _SPACE_POOL;
        SPACE_BNB_PAIR = _PAIR;

        zap = Zap(_zap);
        priceCalculator = PriceCalculator(_priceCalculator);

        withdrawalFeeFreePeriod = 3 days;
        withdrawalFeeRate = 50;
        performanceFeeRate = 3000;

        amountToMintPerProfit = 64e18;

        IBEP20(_SPACE).safeApprove(_SPACE_POOL, 0);
        IBEP20(_SPACE).safeApprove(_SPACE_POOL, uint256(~0));
    }

    // @notice Minter is owned by governance. Useful to update tokenomics in case of governance proposal.
    function transferSpaceOwner(address _owner) external onlyOwner {
        require(_owner != address(this), "SpaceMinter: transferSpaceOwnership address already set");
        require(_owner != address(0), "SpaceMinter: wrong address");

        Ownable(SPACE).transferOwnership(_owner);
    }

    // @notice One-time call. Called after governance set up
    function setGovernance(address _governance) external onlyOwner {
        require(governance == address(0), "Governance already set");
        governance = _governance;
    }

    function updatePriceCalculator(address _priceCalculator) external onlyOwner {
        require(_priceCalculator != address(0), "SpaceMinter: updatePriceCalculator wrong address");
        require(_priceCalculator != address(priceCalculator), "SpaceMinter: updatePriceCalculator address already set");

        priceCalculator = PriceCalculator(_priceCalculator);
    }

    function updateZap(address payable _zap) external onlyOwner {
        require(_zap != address(0), "updateZap: updateZap wrong address");
        require(_zap != address(zap), "SpaceMinter: updateZap address already set");

        zap = Zap(_zap);
    }

    function setWithdrawalFee(uint256 _fee) external onlyOwner {
        require(_fee < MAX_WITHDRAWAL_FEE, "SpaceMinter: setWithdrawalFee fees too high");
        withdrawalFeeRate = _fee;
    }

    // @notice Performance Fee cut in profit. Default 30%.
    function setPerformanceFee(uint256 _fee) external onlyOwner {
        require(_fee < MAX_PERFORMANCE_FEE, "SpaceMinter: setPerformanceFee fees too high");
        performanceFeeRate = _fee;
    }

    // @notice Period during withdrawal fee are active. Default 3 days.
    function setWithdrawalFeeFreePeriod(uint256 _period) external onlyOwner {
        withdrawalFeeFreePeriod = _period;
    }

    // @notice give right to vaults the right to mint SPACE. Must be a contract.
    function updateAccessToMint(address minter, bool canMint) external override onlyOwner {
        require(minter.isContract(), "SpaceMinter: updateAccessToMint only contract are allowed to mint");

        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }

    function updateSpacePerProfit(uint256 _newAmountPerProfit) external onlyOwner {
        amountToMintPerProfit = _newAmountPerProfit;
    }

    function isMinter(address account) public view override returns (bool) {
        if (IBEP20(SPACE).getOwner() != address(this)) {
            return false;
        }
        return _minters[account];
    }

    function amountSpaceToMint(uint256 bnbProfit) public view override returns (uint256) {
        return bnbProfit.mul(amountToMintPerProfit).div(1e18);
    }

    // @notice check if withdrawal fee is applicable for the amount wanted
    function withdrawalFee(uint256 amount, uint256 depositedAt) external view override returns (uint256) {
        if (depositedAt.add(withdrawalFeeFreePeriod) > block.timestamp) {
            return amount.mul(withdrawalFeeRate).div(DENOMINATOR);
        }
        return 0;
    }

    // @notice get performance fee amount cut from profit
    function performanceFee(uint256 profit) public view override returns (uint256) {
        return profit.mul(performanceFeeRate).div(DENOMINATOR);
    }

    function mintFor(
        address asset,
        uint256 withdrawalFeeAmount,
        uint256 performanceFeeAmount,
        address dest,
        uint256 depositedAt
    ) external payable override onlyMinter {
        // Total fee collected
        uint256 totalFee = performanceFeeAmount.add(withdrawalFeeAmount);
        // Get fee from caller
        _transferAsset(asset, totalFee);

        if (asset == address(SPACE)) {
            IBEP20(SPACE).safeTransfer(DEAD, totalFee);
            return;
        }

        // determine value of performance fee.
        (uint256 valueInBNB, ) = priceCalculator.valueOfAsset(asset, totalFee);
        uint256 performanceFeeInBnb = valueInBNB.mul(performanceFeeAmount).div(totalFee);
        uint256 spaceBnbAmount = _zapAssetsToSpaceBnb(asset);

        if (spaceBnbAmount == 0) return;

        IBEP20(SPACE_BNB_PAIR).safeTransfer(SPACE_POOL, spaceBnbAmount);
        IStakingRewards(SPACE_POOL).notifyRewardAmount(spaceBnbAmount);

        // Mint Space according to performance fee BNB value.
        uint256 amountToMint = amountSpaceToMint(performanceFeeInBnb);
        if (amountToMint == 0) return;
        _mint(amountToMint, dest);
    }

    function mint(address dest, uint256 amount) external override onlySpaceChef {
        if (amount == 0) return;
        _mint(amount, dest);
    }

    function safeSpaceTransfer(address _to, uint256 _amount) external override onlySpaceChef {
        if (_amount == 0) return;

        uint256 bal = IBEP20(SPACE).balanceOf(address(this));
        if (_amount <= bal) {
            IBEP20(SPACE).safeTransfer(_to, _amount);
        } else {
            IBEP20(SPACE).safeTransfer(_to, bal);
        }
    }

    // @dev should be called when determining mint in governance. Space is transferred to the timelock contract.
    function mintGov(uint256 amount) external override onlyOwner {
        if (amount == 0) return;
        _mint(amount, governance);
    }

    function _transferAsset(address asset, uint256 amount) private {
        if (asset == address(0)) {
            // in case asset is BNB
            require(msg.value >= amount);
        } else {
            IBEP20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _zapAssetsToSpaceBnb(address asset) private returns (uint256) {
        // Check allowance
        if (asset != address(0) && IBEP20(asset).allowance(address(this), address(zap)) == 0) {
            IBEP20(asset).safeApprove(address(zap), uint256(-1));
        }

        // Swap BNB for SPACE-BNB
        if (asset == address(0)) {
            zap.zapIn{value: address(this).balance}(SPACE_BNB_PAIR);
        } else if (keccak256(abi.encodePacked(IApePair(asset).symbol())) == keccak256("APE-LP")) {
            // Remove LP token
            zap.zapOut(asset, IBEP20(asset).balanceOf(address(this)));

            IApePair pair = IApePair(asset);
            address token0 = pair.token0();
            address token1 = pair.token1();

            if (token0 == WBNB || token1 == WBNB) {
                address token = token0 == WBNB ? token1 : token0;
                if (IBEP20(token).allowance(address(this), address(zap)) == 0) {
                    IBEP20(token).safeApprove(address(zap), uint256(-1));
                }
                zap.zapIn{value: address(this).balance}(SPACE_BNB_PAIR);
                zap.zapInToken(token, IBEP20(token).balanceOf(address(this)), SPACE_BNB_PAIR);
            } else {
                if (IBEP20(token0).allowance(address(this), address(zap)) == 0) {
                    IBEP20(token0).safeApprove(address(zap), uint256(-1));
                }
                if (IBEP20(token1).allowance(address(this), address(zap)) == 0) {
                    IBEP20(token1).safeApprove(address(zap), uint256(-1));
                }

                zap.zapInToken(token0, IBEP20(token0).balanceOf(address(this)), SPACE_BNB_PAIR);
                zap.zapInToken(token1, IBEP20(token1).balanceOf(address(this)), SPACE_BNB_PAIR);
            }
        } else {
            zap.zapInToken(asset, IBEP20(asset).balanceOf(address(this)), SPACE_BNB_PAIR);
        }

        return IBEP20(SPACE_BNB_PAIR).balanceOf(address(this));
    }

    function _mint(uint256 amount, address dest) private {
        require(dest != address(0), "SpaceMinter: _mint to wrong address");
        SPACE.mint(dest, amount);

        // if (dest != address(this)) {
        // spaceToken.transfer(dest, amount);
        // }

        uint256 teamAllocation = amount.mul(15).div(100);
        SPACE.mint(teamAllocation);

        // Automatically stack team allocation into SPACE POOL for fees redistribution.
        IStakingRewards(SPACE_POOL).stakeTo(teamAllocation, DEPLOYER);
    }
}
