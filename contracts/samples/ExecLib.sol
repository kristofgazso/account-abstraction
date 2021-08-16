// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;

import "./IExecutable.sol";

/**
 * helper library, to decode IExecutable.exec() method call.
 */
library ExecLib {

    /**
     * effeciently decode inner called method.
     * - validate the given callData is an "exec" call.
     * - decode the signature, params and dest of that inner call
     * - params are returned as "calldata" reference, to save needless copy.
     * @param callData - a byte array to decode as exec(dest,func)
     * @param expectedMethodSig the encoded function inside the exec must have this signature
     * returns:
     * - success successfully decoded the exec call, with the expected method signature
     * - dest the dest address of the exec call
     * - the params block of the encoded method, ready to be passed to abi.decode
     */
    function decodeExecMethod(bytes calldata callData, bytes4 expectedMethodSig) internal pure returns (bool success, address dest, bytes calldata params) {
        if (isExec(callData)) {
            bytes4 methodSig;
            (dest, methodSig, params) = decodeExecMethod(callData);
            success = methodSig == expectedMethodSig;
        } else {
            success = false;
            params=callData[0:0]; //not to be used, but has to be set to avoid compiler error.
        }
    }

    //return true if the given callData is IExecutable.exec()
    function isExec(bytes calldata callData) pure internal returns (bool){
        return callData.length > 4 && bytes4(callData[0 : 4]) == IExecutable.exec.selector;
    }

    //decode a call to "exec"
    // for convenience, also break the "func" into methodSig and params.
    // @param: callData of "exec(dest,func)
    function decodeExecMethod(bytes calldata callData) internal pure returns (address dest, bytes4 methodSig, bytes calldata params) {
        //we need to decode the "bytes func" parameter, so we need to extract
        // it as a "calldata", not "memory".
        // so here we only decode its offset (into the callData[4:].
        // at that offset there is length followed by dunamic value.
        uint funcOffset;
        (dest, funcOffset) = abi.decode(callData[4 :], (address, uint));
        funcOffset += 4;
        uint len = uint(bytes32(callData[funcOffset :]));
        funcOffset += 32;
        methodSig = bytes4(callData[funcOffset :]);
        params = callData[funcOffset + 4 : funcOffset + len];
    }
}

