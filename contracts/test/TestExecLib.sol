// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;

import "../samples/ExecLib.sol";

contract TestExecLib {
    function isExec(bytes calldata callData) pure public returns (bool){
        return ExecLib.isExec(callData);
    }

    function decodeExecMethod(bytes calldata callData) public pure returns (address dest, bytes4 methodSig, bytes calldata params) {
        return ExecLib.decodeExecMethod(callData);
    }
}