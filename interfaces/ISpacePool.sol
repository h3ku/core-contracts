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

struct Profit {
    uint256 usd;
    uint256 space;
    uint256 bnb;
}

struct APY {
    uint256 usd;
    uint256 space;
    uint256 bnb;
}

struct UserInfo {
    uint256 balance;
    uint256 principal;
    uint256 available;
    Profit profit;
    uint256 poolTVL;
    APY poolAPY;
}

interface ISpacePool {
    function deposit(uint256 _amount) external;

    function depositAll() external;

    function withdraw(uint256 _amount) external;

    function withdrawAll() external;

    function getReward() external;

    function balance() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function principalOf(address account) external view returns (uint256);

    function profitOf(address account)
        external
        view
        returns (
            uint256 _usd,
            uint256 _space,
            uint256 _bnb
        );

    //    function earned(address account) external view returns (uint);
    function tvl() external view returns (uint256); // in USD

    function apy()
        external
        view
        returns (
            uint256 _usd,
            uint256 _space,
            uint256 _bnb
        );

    /* ========== Strategy Information ========== */
    //    function pid() external view returns (uint);
    //    function poolType() external view returns (PoolTypes);
    //    function isMinter() external view returns (bool, address);
    //    function getDepositedAt(address account) external view returns (uint);
    //    function getRewardsToken() external view returns (address);

    function info(address account) external view returns (UserInfo memory);
}
