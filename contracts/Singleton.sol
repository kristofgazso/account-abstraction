// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.7;

import "./StakeManager.sol";
import "./UserOperation.sol";
import "./IWallet.sol";
import "./IPaymaster.sol";

contract Singleton is StakeManager {

    enum PaymentMode {
        walletEth, walletStake, paymasterStake
    }
    using UserOperationLib for UserOperation;
    // paymaster locked stake
    // (actual stake should be higher, to cover actual call cost)
    uint256 constant PAYMASTER_STAKE = 1 ether;

    uint public immutable perOpOverhead;

    event UserOperationEvent(address indexed account, address indexed paymaster, uint actualGasCost, uint actualGasPrice, bool success);
    event UserOperationRevertReason(address indexed account, bytes revertReason);

    event PaymasterPostOpFailed(address paymaster, address target, bytes reason);

    //handleOps reverts with this error struct, to mark the offending op
    // NOTE: if simulateOp passes successfully, there should be no reason for handleOps to fail on it.
    // @param opIndex - index into the array of ops to the failed one (in simulateOp, this is always zero)
    // @param paymaster - if paymaster.payForOp fails, this will be the paymaster's address. if payForSelfOp failed,
    //      this value will be zero (since it failed before accessing the paymaster)
    // @param reason - revert reason
    //  only to aid troubleshooting of wallet/paymaster reverts
    error FailedOp(uint opIndex, address paymaster, string reason);

    constructor(uint _perOpOverhead, uint32 _unstakeDelayBlocks) StakeManager(_unstakeDelayBlocks) {
        perOpOverhead = _perOpOverhead;
    }

    receive() external payable {}

    /**
     * Execute the given UserOperation.
     * @param op the operation to execute
     * @param redeemer the contract to redeem the fee
     */
    function handleOp(UserOperation calldata op, address payable redeemer) public {

        uint preGas = gasleft();
        uint256 savedBalance = address(this).balance;

        (uint256 prefund, PaymentMode paymentMode, bytes memory context) = _validatePrepayment(0, op);
        uint preOpGas = preGas - gasleft() + perOpOverhead;

        uint valueFromStake;

        try this.internalHandleOp(op, context, preOpGas, prefund, paymentMode) returns (uint _valueFromPaymaster) {
            valueFromStake = _valueFromPaymaster;
        } catch {
            uint actualGas = preGas - gasleft() + preOpGas;
            valueFromStake = handlePostOp(IPaymaster.PostOpMode.postOpReverted, op, context, actualGas, prefund, paymentMode);
        }
        uint collected = address(this).balance - savedBalance + valueFromStake;

        redeemer.transfer(collected);
    }

    function handleOps(UserOperation[] calldata ops, address payable redeemer) public {

        uint256 savedBalance = address(this).balance;
        uint opslen = ops.length;
        uint256[] memory preOpGas = new uint256[](opslen);
        bytes32[] memory contexts = new bytes32[](opslen);
        uint256[] memory prefunds = new uint256[](opslen);
        PaymentMode[] memory paymentModes = new PaymentMode[](opslen);

        for (uint i = 0; i < opslen; i++) {
            uint preGas = gasleft();
            UserOperation calldata op = ops[i];

            bytes memory context;
            bytes32 contextOffset;
            (prefunds[i], paymentModes[i], context) = _validatePrepayment(i, op);
            assembly {contextOffset := context}
            contexts[i] = contextOffset;
            preOpGas[i] = preGas - gasleft() + perOpOverhead;
        }

        uint valueFromStake = 0;
        for (uint i = 0; i < ops.length; i++) {
            uint preGas = gasleft();
            UserOperation calldata op = ops[i];
            bytes32 contextOffset = contexts[i];
            bytes memory context;
            assembly {context := contextOffset}
            uint valueFromPaymaster;
            uint preOpGasi = preOpGas[i];
            uint prefundi = prefunds[i];
            PaymentMode paymentModei = paymentModes[i];

            try this.internalHandleOp(op, context, preOpGasi, prefundi, paymentModei) returns (uint _valueFromPaymaster) {
                valueFromPaymaster = _valueFromPaymaster;
            } catch {
                uint actualGas = preGas - gasleft() + preOpGasi;
                valueFromPaymaster = handlePostOp(IPaymaster.PostOpMode.postOpReverted, op, context, actualGas, prefundi, paymentModei);
            }

            valueFromStake += valueFromPaymaster;
        }

        uint collected = address(this).balance - savedBalance + valueFromStake;

        redeemer.transfer(collected);
    }

    function internalHandleOp(UserOperation calldata op, bytes calldata context, uint preOpGas, uint prefund, PaymentMode paymentMode) external returns (uint valueFromStake) {
        uint preGas = gasleft();
        require(msg.sender == address(this));

        IPaymaster.PostOpMode mode = IPaymaster.PostOpMode.opSucceeded;
        if (op.callData.length > 0) {

            (bool success,bytes memory result) = address(op.target).call{gas : op.callGas}(op.callData);
            if (!success) {
                emit UserOperationRevertReason(op.target, result);
                mode = IPaymaster.PostOpMode.opReverted;
            }
        }

        uint actualGas = preGas - gasleft() + preOpGas;
        return handlePostOp(mode, op, context, actualGas, prefund, paymentMode);
    }

    /**
     * Simulate a call for wallet.payForSelfOp.
     * Call must not revert.
     * @return gasUsedByPayForSelfOp - gas used by the validation, to pass into simulatePaymasterValidation.
     * The node must also verify it doesn't use banned opcode, and that it doesn't reference storage outside the wallet's data
     */
    function simulateWalletValidation(UserOperation calldata userOp) external returns (uint gasUsedByPayForSelfOp){
        require(msg.sender == address(0), "must be called off-chain with from=zero-addr");
        uint requiredPreFund = userOp.requiredPreFund(perOpOverhead);
        PaymentMode paymentMode = _walletRequiredPrefund(userOp, requiredPreFund);
        (gasUsedByPayForSelfOp,) = _validateWalletPrepayment(0, userOp, requiredPreFund, paymentMode);
    }

    function _walletRequiredPrefund(UserOperation calldata userOp, uint prefund) internal view returns (PaymentMode paymentMode) {
        if (userOp.hasPaymaster()) {
            return PaymentMode.paymasterStake;
        }
        uint walletStake = stakes[userOp.target].stake;
        if (walletStake > prefund) {
            return PaymentMode.walletStake;
        }
        return PaymentMode.walletEth;
    }

    /**
     * Simulate a call to paymaster.payForOp
     * do nothing if has no paymaster.
     * @param userOp the user operation to validate.
     * @param gasUsedByPayForSelfOp - the gas returned by simulateWalletValidation, as these 2 calls should share
     *  the same userOp.validationGas quota.
     * The node must also verify it doesn't use banned opcode, and that it doesn't reference storage outside the paymaster's data
     */
    function simulatePaymasterValidation(UserOperation calldata userOp, uint gasUsedByPayForSelfOp) external view returns (bytes memory context, uint gasUsedByPayForOp){
        if (!userOp.hasPaymaster()) {
            return ("", 0);
        }
        uint requiredPreFund = userOp.requiredPreFund(perOpOverhead);
        return _validatePaymasterPrepayment(0, userOp, requiredPreFund, gasUsedByPayForSelfOp);
    }

    function _create2(bytes calldata initCode, uint salt) internal returns (address target) {
        bytes memory createData = initCode;
        assembly {
            target := create2(0, add(createData, 32), mload(createData), salt)
        }
    }

    // get the target address, or use "create2" to create it.
    // note that the gas allocation for this creation is deterministic (by the size of callData),
    // so it is not checked on-chain, and adds to the gas used by payForSelfOp
    function _createTargetIfNeeded(UserOperation calldata op) internal {
        if (op.initCode.length != 0) {
            //its a create operation. run the create2
            // note that we're still under the gas limit of validate, so probably
            // this create2 creates a proxy account.
            // appending signer makes the request unique, so no one else can make this request.
            //nonce is meaningless during create, so we re-purpose it as salt
            address target1 = _create2(op.initCode, op.nonce);
            require(target1 != address(0), "create2 failed");
            require(target1 == op.target, "target doesn't match create2 address");
        }
    }

    //get counterfactual account address.
    function getAccountAddress(bytes memory bytecode, uint _salt) public view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                _salt,
                keccak256(bytecode)
            )
        );

        // NOTE: cast last 20 bytes of hash to address
        return address(uint160(uint256(hash)));
    }

    //call wallet.payForSelfOp, and validate that it paid as needed.
    // return actual value sent from wallet to "this"
    function _validateWalletPrepayment(uint opIndex, UserOperation calldata op, uint walletRequiredPrefund, PaymentMode paymentMode) internal returns (uint gasUsedByPayForSelfOp, uint prefund) {
        uint preGas = gasleft();
        _createTargetIfNeeded(op);
        uint preBalance = address(this).balance;
        uint requiredEthPrefund = 0;
        if (paymentMode == PaymentMode.walletEth) {
            requiredEthPrefund = walletRequiredPrefund;
        } else if (paymentMode == PaymentMode.walletStake) {
            stakes[op.target].stake -= uint96(walletRequiredPrefund);
            prefund = walletRequiredPrefund;
        } else {
            prefund = 0; //paymaster mode - no wallet prefund.
        }
        try IWallet(op.target).payForSelfOp{gas : op.verificationGas}(op, requiredEthPrefund) {
        } catch Error(string memory revertReason) {
            revert FailedOp(opIndex, address(0), revertReason);
        } catch {
            revert FailedOp(opIndex, address(0), "");
        }
        uint actualEthPrefund = address(this).balance - preBalance;

        if (requiredEthPrefund > 0) {
            if (actualEthPrefund < requiredEthPrefund) {
                revert FailedOp(opIndex, address(0), "wallet didn't pay prefund");
            }
            prefund = actualEthPrefund;
        } else {
            if (actualEthPrefund != 0) {
                revert FailedOp(opIndex, address(0), "has paymaster but wallet paid");
            }
        }
        gasUsedByPayForSelfOp = preGas - gasleft();
    }

    //validate paymaster.payForOp
    function _validatePaymasterPrepayment(uint opIndex, UserOperation calldata op, uint requiredPreFund, uint gasUsedByPayForSelfOp) internal view returns (bytes memory context, uint gasUsedByPayForOp) {
        uint preGas = gasleft();
        if (!isValidPaymasterStake(op, requiredPreFund)) {
            revert FailedOp(opIndex, op.paymaster, "not enough stake");
        }
        //no pre-pay from paymaster
        uint gas = op.verificationGas - gasUsedByPayForSelfOp;
        try IPaymaster(op.paymaster).payForOp{gas : gas}(op, requiredPreFund) returns (bytes memory _context){
            context = _context;
        } catch Error(string memory revertReason) {
            revert FailedOp(opIndex, op.paymaster, revertReason);
        } catch {
            revert FailedOp(opIndex, op.paymaster, "");
        }
        gasUsedByPayForOp = preGas - gasleft();
    }

    function _validatePrepayment(uint opIndex, UserOperation calldata op) private returns (uint prefund, PaymentMode paymentMode, bytes memory context){

        uint preGas = gasleft();
        uint requiredPreFund = op.requiredPreFund(perOpOverhead);
        paymentMode = _walletRequiredPrefund(op, requiredPreFund);
        uint gasUsedByPayForSelfOp;
        (gasUsedByPayForSelfOp, prefund) = _validateWalletPrepayment(opIndex, op, requiredPreFund, paymentMode);

        uint gasUsedByPayForOp = 0;
        if (op.hasPaymaster()) {
            (context, gasUsedByPayForOp) = _validatePaymasterPrepayment(opIndex, op, requiredPreFund, gasUsedByPayForSelfOp);
        }
        uint gasUsed = preGas - gasleft();

        if (op.verificationGas < gasUsed) {
            revert FailedOp(opIndex, op.paymaster, "Used more than verificationGas");
        }
    }

    function getPaymastersStake(address[] calldata paymasters) external view returns (uint[] memory _stakes) {
        _stakes = new uint[](paymasters.length);
        for (uint i = 0; i < paymasters.length; i++) {
            _stakes[i] = stakes[paymasters[i]].stake;
        }
    }

    function handlePostOp(IPaymaster.PostOpMode mode, UserOperation calldata op, bytes memory context, uint actualGas, uint prefund, PaymentMode paymentMode) private returns (uint valueFromStake) {
        uint preGas = gasleft();
        uint gasPrice = UserOperationLib.gasPrice(op);
        uint actualGasCost = actualGas * gasPrice;
        if (paymentMode != PaymentMode.paymasterStake) {
            if (prefund < actualGasCost) {
                //TODO: should not happen.
                revert ("fatal: prefund below actualGasCost");
            }
            uint refund = prefund - actualGasCost;
            if (paymentMode == PaymentMode.walletStake) {
                stakes[op.target].stake += uint96(refund);
                valueFromStake = actualGasCost;
            } else {

                //NOTE: deliberately ignoring revert: wallet should accept refund.
                bool sendOk = payable(op.target).send(refund);
                (sendOk);
                //charged wallet directly.
                valueFromStake = 0;
            }
        } else {
            if (context.length > 0) {
                //if paymaster.postOp reverts:
                // - emit a message (just for sake of debugging of this poor paymaster)
                // - paymaster still pays (from its stake)
                try IPaymaster(op.paymaster).postOp(mode, context, actualGasCost) {}
                catch (bytes memory errdata) {
                    emit PaymasterPostOpFailed(op.paymaster, op.target, errdata);
                }
            }
            //paymaster pays for full gas, including for postOp (and revert event)
            actualGas += preGas - gasleft();
            actualGasCost = actualGas * gasPrice;
            //paymaster balance known to be high enough, and to be locked for this block
            stakes[op.paymaster].stake -= uint96(actualGasCost);

            valueFromStake = actualGasCost;
        }
        emit UserOperationEvent(op.target, op.paymaster, actualGasCost, gasPrice, mode == IPaymaster.PostOpMode.opSucceeded);
    }

    function isValidPaymasterStake(UserOperation calldata op, uint requiredPreFund) internal view returns (bool) {
        return isStaked(op.paymaster, PAYMASTER_STAKE + requiredPreFund);
    }

    function isContractDeployed(address addr) external view returns (bool) {
        bytes32 hash;
        assembly {
            hash := extcodehash(addr)
        }
        return hash != bytes32(0);
    }
}

