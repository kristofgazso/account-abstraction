// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../IPaymaster.sol";
import "../Singleton.sol";
import "./SimpleWalletForTokens.sol";
import "hardhat/console.sol";

import "./ExecLib.sol";
import "hardhat/console.sol";
/**
 * A sample paymaster that uses the user's token to pay for gas.
 * NOTE: actual paymaster should use some price oracle, and might also attempt to swap tokens for ETH.
 * for simplicity, this contract uses hard-coded token price, and assumes its owner should provide it with enough
 * eth (and collect the accumulated tokens)
 */
contract TokenPaymaster is Ownable, IPaymaster {

    //calculated cost of the postOp
    uint COST_OF_POST = 30000;

    IERC20 immutable token;
    Singleton immutable singleton;

    //known constructor that calls "approve"
    mapping(bytes32 => bool) public knownWalletConstructor;

    //known wallet runtime, that supports "exec"
    //  (needed to allow payment of "approve" call)
    mapping(bytes32 => bool) public knownWalletRuntime;

    constructor(Singleton _singleton, IERC20 _token) {
        singleton = _singleton;
        token = _token;
        knownWalletConstructor[keccak256(type(SimpleWalletForTokens).creationCode)] = true;

        knownWalletRuntime[keccak256(type(SimpleWalletForTokens).runtimeCode)] = true;
        knownWalletRuntime[keccak256(type(SimpleWallet).runtimeCode)] = true;
    }

    function _onlyThroughSingleton() internal view {
        console.log('sender %s singleton %s', msg.sender, address(singleton));
        require(msg.sender == address(singleton) , "postOp: only through singleton");
    }

    modifier onlyThroughSingleton() {
        _onlyThroughSingleton();
        _;
    }

    //after successful transactions, this paymaster accumulates tokens.
    function withdrawTokens(address withdrawAddress, uint amount) external onlyOwner {
        token.transfer(withdrawAddress, amount);
    }

    //owner should call and put eth into it.
    function addStake() external payable {
        singleton.addStake{value : msg.value}();
    }

    //TODO: this method assumes a fixed ratio of token-to-eth. should use oracle.
    function ethToToken(uint valueEth) public pure returns (uint valueToken) {
        return valueEth / 100;
    }

    // verify that the user has enough tokens.
    function payForOp(UserOperation calldata userOp) external view override returns (bytes32 context) {
        uint tokenPrefund = ethToToken(UserOperationLib.requiredPreFund(userOp));

        address target = userOp.target;
        if (userOp.initCode.length != 0) {
            bytes32 bytecodeHash = keccak256(userOp.initCode);
            require(knownWalletConstructor[bytecodeHash], "TokenPaymaster: unknown wallet constructor");
            //TODO: must also whitelist init function (callData), since that what will call "token.approve(paymaster)"
            //no "allowance" check during creation (we trust known constructor/init function)
            require(token.balanceOf(target) > tokenPrefund, "TokenPaymaster: no balance (pre-create)");
            return bytes32(uint(1));
        }

        require(token.balanceOf(target) > tokenPrefund, "TokenPaymaster: no balance");

        if (token.allowance(target, address(this)) < tokenPrefund) {

            uint preGas = gasleft();

            //can only trust the "exec" method of known wallet code.
            bytes32 bytecodeHash;
            assembly {
                bytecodeHash := extcodehash(target)
            }
            require(knownWalletRuntime[bytecodeHash], "TokenPaymaster: unknown wallet");

            (bool success, address _dest, bytes calldata params) = ExecLib.decodeExecMethod(userOp.callData, IERC20.approve.selector);
            if (success) {
                (address _spender, uint _amount) = abi.decode(params, (address,uint));

                uint postGas = gasleft();
                console.log("=== eval approve gasUsed: %s", preGas - postGas);

                require(_dest == address(token), "approve: wrong token");
                require(_spender == address(this), "approve: spender not me");
                require(_amount >= tokenPrefund, "approve: amount<tokenPrefund");

                return bytes32(uint(1));
            }
            //TODO: allowance too low. just before reverting, can check if current operation is "token.approve(paymaster)"
            // this is a multi-step operation: first, verify "callData" is exec(token, innerData)
            //     (this requires knowing the "execute" signature of the wallet
            // then verify that "innerData" is approve(paymaster,-1)
            revert("TokenPaymaster: no allowance");
        }
        return bytes32(uint(1));
    }

    //actual charge of user.
    // this method will be called just after the user's TX with postRevert=false.
    // BUT: if the user changed its balance and that postOp reverted, then it gets called again, after reverting
    // the user's TX
    function postOp(PostOpMode mode, UserOperation calldata userOp, bytes32 context, uint actualGasCost) external override {
        //we don't really care about the mode, we just pay the gas with the user's tokens.
        (mode,context);
        uint charge = ethToToken(actualGasCost + COST_OF_POST * UserOperationLib.gasPrice(userOp));
        //actualGasCost is known to be no larger than the above requiredPreFund, so the transfer should succeed.
        token.transferFrom(userOp.target, address(this), charge);
    }
}
