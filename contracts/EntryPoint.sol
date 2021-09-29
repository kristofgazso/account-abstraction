// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.7;

import "./StakeManager.sol";
import "./UserOperation.sol";
import "./IWallet.sol";
import "./IPaymaster.sol";

contract EntryPoint is StakeManager {

    using UserOperationLib for UserOperation;
    // paymaster locked stake
    // (actual stake should be higher, to cover actual call cost)
    uint256 constant PAYMASTER_STAKE = 1 ether;

    enum PaymentMode {
        paymasterStake, // if paymaster is set, use paymaster's stake to pay.
        walletStake, // wallet has enough stake to pay for request.
        walletEth // wallet has no stake. paying with eth.
    }

    uint public immutable perOpOverhead;

    event UserOperationEvent(address indexed account, address indexed paymaster, uint actualGasCost, uint actualGasPrice, bool success);
    event UserOperationRevertReason(address indexed account, bytes revertReason);

    event PaymasterPostOpFailed(address paymaster, address sender, bytes reason);

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

        (uint256 prefund, PaymentMode paymentMode, bytes memory context) = _validatePrepayment(0, op);
        uint preOpGas = preGas - gasleft() + perOpOverhead;

        uint actualGasCost;

        try this.internalHandleOp(op, context, preOpGas, prefund, paymentMode) returns (uint _actualGasCost) {
            actualGasCost = _actualGasCost;
        } catch {
            uint actualGas = preGas - gasleft() + preOpGas;
            actualGasCost = handlePostOp(IPaymaster.PostOpMode.postOpReverted, op, context, actualGas, prefund, paymentMode);
        }

        redeemer.transfer(actualGasCost);
    }

    function handleOps(UserOperation[] calldata ops, address payable redeemer) public {

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

        uint collected = 0;

        for (uint i = 0; i < ops.length; i++) {
            uint preGas = gasleft();
            UserOperation calldata op = ops[i];
            bytes32 contextOffset = contexts[i];
            bytes memory context;
            assembly {context := contextOffset}
            uint preOpGasi = preOpGas[i];
            uint prefundi = prefunds[i];
            PaymentMode paymentModei = paymentModes[i];

            try this.internalHandleOp(op, context, preOpGasi, prefundi, paymentModei) returns (uint _actualGasCost) {
                collected += _actualGasCost;
            } catch {
                uint actualGas = preGas - gasleft() + preOpGasi;
                collected += handlePostOp(IPaymaster.PostOpMode.postOpReverted, op, context, actualGas, prefundi, paymentModei);
            }
        }

        redeemer.transfer(collected);
    }

    function internalHandleOp(UserOperation calldata op, bytes calldata context, uint preOpGas, uint prefund, PaymentMode paymentMode) external returns (uint actualGasCost) {
        uint preGas = gasleft();
        require(msg.sender == address(this));

        IPaymaster.PostOpMode mode = IPaymaster.PostOpMode.opSucceeded;
        if (op.callData.length > 0) {

            (bool success,bytes memory result) = address(op.sender).call{gas : op.callGas}(op.callData);
            if (!success && result.length > 0) {
                emit UserOperationRevertReason(op.sender, result);
                mode = IPaymaster.PostOpMode.opReverted;
            }
        }

        uint actualGas = preGas - gasleft() + preOpGas;
        return handlePostOp(mode, op, context, actualGas, prefund, paymentMode);
    }

    /**
     * Simulate a call for wallet.verifyUserOp.
     * Call must not revert.
     * @return gasUsedByPayForSelfOp - gas used by the validation, to pass into simulatePaymasterValidation.
     * The node must also verify it doesn't use banned opcode, and that it doesn't reference storage outside the wallet's data
     */
    function simulateWalletValidation(UserOperation calldata userOp) external returns (uint gasUsedByPayForSelfOp){
        require(msg.sender == address(0), "must be called off-chain with from=zero-addr");
        (uint requiredPreFund, PaymentMode paymentMode) = getPaymentInfo(userOp);
        (gasUsedByPayForSelfOp,) = _validateWalletPrepayment(0, userOp, requiredPreFund, paymentMode);
    }

    function getPaymentInfo(UserOperation calldata userOp) internal view returns (uint requiredPrefund, PaymentMode paymentMode) {
        requiredPrefund = userOp.requiredPreFund(perOpOverhead);
        if (userOp.hasPaymaster()) {
            paymentMode = PaymentMode.paymasterStake;
        } else if (isStaked(userOp.sender, requiredPrefund, 0)) {
            paymentMode = PaymentMode.walletStake;
        } else {
            paymentMode = PaymentMode.walletEth;
        }
    }

    /**
     * Simulate a call to paymaster.verifyPaymasterUserOp
     * do nothing if has no paymaster.
     * @param userOp the user operation to validate.
     * @param gasUsedByPayForSelfOp - the gas returned by simulateWalletValidation, as these 2 calls should share
     *  the same userOp.validationGas quota.
     * The node must also verify it doesn't use banned opcode, and that it doesn't reference storage outside the paymaster's data
     */
    function simulatePaymasterValidation(UserOperation calldata userOp, uint gasUsedByPayForSelfOp) external view returns (bytes memory context, uint gasUsedByPayForOp){
        (uint requiredPreFund, PaymentMode paymentMode) = getPaymentInfo(userOp);
        if (paymentMode != PaymentMode.paymasterStake) {
            return ("", 0);
        }
        return _validatePaymasterPrepayment(0, userOp, requiredPreFund, gasUsedByPayForSelfOp);
    }

    function _create2(bytes calldata initCode, uint salt) internal returns (address sender) {
        bytes memory createData = initCode;
        assembly {
            sender := create2(0, add(createData, 32), mload(createData), salt)
        }
    }

    // get the target address, or use "create2" to create it.
    // note that the gas allocation for this creation is deterministic (by the size of callData),
    // so it is not checked on-chain, and adds to the gas used by payForSelfOp
    function _createSenderIfNeeded(UserOperation calldata op) internal {
        if (op.initCode.length != 0) {
            //its a create operation. run the create2
            // note that we're still under the gas limit of validate, so probably
            // this create2 creates a proxy account.
            // appending signer makes the request unique, so no one else can make this request.
            //nonce is meaningless during create, so we re-purpose it as salt
            address sender1 = _create2(op.initCode, op.nonce);
            require(sender1 != address(0), "create2 failed");
            require(sender1 == op.sender, "sender doesn't match create2 address");
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
    function _validateWalletPrepayment(uint opIndex, UserOperation calldata op, uint requiredPrefund, PaymentMode paymentMode) internal returns (uint gasUsedByPayForSelfOp, uint prefund) {
        uint preGas = gasleft();
        _createSenderIfNeeded(op);
        uint preBalance = address(this).balance;
        uint requiredEthPrefund = 0;
        if (paymentMode == PaymentMode.walletEth) {
            requiredEthPrefund = requiredPrefund;
        } else if (paymentMode == PaymentMode.walletStake) {
            stakes[op.sender].stake -= uint96(requiredPrefund);
        } else {
            // paymaster pays in handlePostOp
        }
        try IWallet(op.sender).verifyUserOp{gas : op.verificationGas}(op, requiredEthPrefund) {
        } catch Error(string memory revertReason) {
            revert FailedOp(opIndex, address(0), revertReason);
        } catch {
            revert FailedOp(opIndex, address(0), "");
        }
        uint actualEthPrefund = address(this).balance - preBalance;

        if (paymentMode == PaymentMode.walletEth) {
            if (actualEthPrefund < requiredEthPrefund) {
                revert FailedOp(opIndex, address(0), "wallet didn't pay prefund");
            }
            prefund = actualEthPrefund;
        } else if (paymentMode == PaymentMode.walletStake) {
            if (actualEthPrefund != 0) {
                revert FailedOp(opIndex, address(0), "using wallet stake but wallet paid eth");
            }
            prefund = requiredPrefund;
        } else {
            if (actualEthPrefund != 0) {
                revert FailedOp(opIndex, address(0), "has paymaster but wallet paid");
            }
            prefund = requiredPrefund;
        }

        gasUsedByPayForSelfOp = preGas - gasleft();
    }

    //validate paymaster.payForOp
    function _validatePaymasterPrepayment(uint opIndex, UserOperation calldata op, uint requiredPreFund, uint gasUsedByPayForSelfOp) internal view returns (bytes memory context, uint gasUsedByPayForOp) {
        uint preGas = gasleft();
        if (!isValidStake(op, requiredPreFund)) {
            revert FailedOp(opIndex, op.paymaster, "not enough stake");
        }
        //no pre-pay from paymaster
        uint gas = op.verificationGas - gasUsedByPayForSelfOp;
        try IPaymaster(op.paymaster).verifyPaymasterUserOp{gas : gas}(op, requiredPreFund) returns (bytes memory _context){
            context = _context;
        } catch Error(string memory revertReason) {
            revert FailedOp(opIndex, op.paymaster, revertReason);
        } catch {
            revert FailedOp(opIndex, op.paymaster, "");
        }
        gasUsedByPayForOp = preGas - gasleft();
    }

    function _validatePrepayment(uint opIndex, UserOperation calldata userOp) private returns (uint prefund, PaymentMode paymentMode, bytes memory context){

        uint preGas = gasleft();
        uint gasUsedByPayForSelfOp;
        uint requiredPreFund;
        (requiredPreFund, paymentMode) = getPaymentInfo(userOp);

        (gasUsedByPayForSelfOp, prefund) = _validateWalletPrepayment(opIndex, userOp, requiredPreFund, paymentMode);

        uint gasUsedByPayForOp = 0;
        if (paymentMode == PaymentMode.paymasterStake) {
            (context, gasUsedByPayForOp) = _validatePaymasterPrepayment(opIndex, userOp, requiredPreFund, gasUsedByPayForSelfOp);
        } else {
            context = "";
        }
        uint gasUsed = preGas - gasleft();

        if (userOp.verificationGas < gasUsed) {
            revert FailedOp(opIndex, userOp.paymaster, "Used more than verificationGas");
        }
    }

    function getPaymastersStake(address[] calldata paymasters) external view returns (uint[] memory _stakes) {
        _stakes = new uint[](paymasters.length);
        for (uint i = 0; i < paymasters.length; i++) {
            _stakes[i] = stakes[paymasters[i]].stake;
        }
    }

    function handlePostOp(IPaymaster.PostOpMode mode, UserOperation calldata op, bytes memory context, uint actualGas, uint prefund, PaymentMode paymentMode) private returns (uint actualGasCost) {
        uint preGas = gasleft();
        uint gasPrice = UserOperationLib.gasPrice(op);
        actualGasCost = actualGas * gasPrice;
        if (paymentMode != PaymentMode.paymasterStake) {
            if (prefund < actualGasCost) {
                revert ("wallet prefund below actualGasCost");
            }
            uint refund = prefund - actualGasCost;
            if (paymentMode == PaymentMode.walletStake) {
                stakes[op.sender].stake += uint96(refund);
            } else {
                //NOTE: deliberately ignoring revert: wallet should accept refund.
                bool sendOk = payable(op.sender).send(refund);
                (sendOk);
            }
        } else {
            if (context.length > 0) {
                //if paymaster.postOp reverts:
                // - emit a message (just for sake of debugging of this poor paymaster)
                // - paymaster still pays (from its stake)
                try IPaymaster(op.paymaster).postOp(mode, context, actualGasCost) {}
                catch (bytes memory errdata) {
                    emit PaymasterPostOpFailed(op.paymaster, op.sender, errdata);
                }
            }
            //paymaster pays for full gas, including for postOp (and revert event)
            actualGas += preGas - gasleft();
            actualGasCost = actualGas * gasPrice;
            //paymaster balance known to be high enough, and to be locked for this block
            stakes[op.paymaster].stake -= uint96(actualGasCost);
        }
        emit UserOperationEvent(op.sender, op.paymaster, actualGasCost, gasPrice, mode == IPaymaster.PostOpMode.opSucceeded);
    }

    function isValidStake(UserOperation calldata op, uint requiredPreFund) internal view returns (bool) {
        return isPaymasterStaked(op.paymaster, PAYMASTER_STAKE + requiredPreFund);
    }

    function isPaymasterStaked(address paymaster, uint stake) public view returns (bool) {
        return isStaked(paymaster, stake, unstakeDelayBlocks);
    }

    function isContractDeployed(address addr) external view returns (bool) {
        bytes32 hash;
        assembly {
            hash := extcodehash(addr)
        }
        return hash != bytes32(0);
    }
}
