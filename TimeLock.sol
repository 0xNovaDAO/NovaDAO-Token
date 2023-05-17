// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";

/*
* @dev Implementation of a simple timelock mechanism for protecting high-security functions.
*
* The modifier withTimelock(functionName) can be added to any function, ensuring any use
* is preceeded by a 24hr wait period, and an appropriate event emission. Following execution
* of the function, the lock will be automatically re-applied.
*/

contract TimeLock is Ownable {
    uint256 public constant lockDuration = 24 hours;

    mapping(bytes32 => uint256) public unlockTimestamps;

    event FunctionUnlocked(bytes32 indexed functionIdentifier, uint256 unlockTimestamp);

    modifier withTimelock(string memory functionName) {
        bytes32 functionIdentifier = keccak256(bytes(functionName));
        require(unlockTimestamps[functionIdentifier] != 0, "Function is locked");
        require(block.timestamp >= unlockTimestamps[functionIdentifier], "Timelock is active");
        _;
        lockFunction(functionName);
    }

    function unlockFunction(string memory functionName) public onlyOwner {
        bytes32 functionIdentifier = keccak256(bytes(functionName));
        uint256 unlockTimestamp = block.timestamp + lockDuration;
        unlockTimestamps[functionIdentifier] = unlockTimestamp;
        emit FunctionUnlocked(functionIdentifier, unlockTimestamp);
    }

    function lockFunction(string memory functionName) internal {
        bytes32 functionIdentifier = keccak256(bytes(functionName));
        unlockTimestamps[functionIdentifier] = 0;
    }
}