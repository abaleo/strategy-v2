// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IOracleTmp {
    /**
     * @notice Data feed address
     */
    function source() external view returns (address);

    /**
     * @notice Doesn't refresh the price, but returns the latest value available without doing any transactional operations:
     * @return value in wei
     */
    function peek(bytes32 base, bytes32 quote, uint256 amount) external view returns (uint256 value, uint256 updateTime);

    /**
     * @notice Does whatever work or queries will yield the most up-to-date price, and returns it.
     * @return value in wei
     */
    function get(bytes32 base, bytes32 quote, uint256 amount) external returns (uint256 value, uint256 updateTime);

    /**
     * @notice Number of decimals in the amounts returned by the oracle.
     */
    function decimals() external view returns (uint8);
}
