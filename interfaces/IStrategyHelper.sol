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

import "./ISpaceMinter.sol";

interface IStrategyHelper {
    function tokenPriceInBNB(address _token) external view returns (uint256);

    function bananaPriceInBNB() external view returns (uint256);

    function bnbPriceInUSD() external view returns (uint256);

    function profitOf(
        ISpaceMinter minter,
        address _flip,
        uint256 amount
    )
        external
        view
        returns (
            uint256 _usd,
            uint256 _space,
            uint256 _bnb
        );

    function tvl(address _flip, uint256 amount) external view returns (uint256); // in USD

    function tvlInBNB(address _flip, uint256 amount) external view returns (uint256); // in BNB

    function apy(ISpaceMinter minter, uint256 pid)
        external
        view
        returns (
            uint256 _usd,
            uint256 _space,
            uint256 _bnb
        );

    function compoundingAPY(uint256 pid, uint256 compoundUnit) external view returns (uint256);
}
