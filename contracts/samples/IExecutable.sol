// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;

//actual account API.
// methods should be protected to be called by rightful owner or by Singleton.
// singleton only calls after payForSelfOp succeeds.
// (paymaster needs to know it only to be able to accept the "approve" tx
interface IExecutable {
    function exec(address dest, bytes calldata func) external;
}

