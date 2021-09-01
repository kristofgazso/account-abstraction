import {describe} from 'mocha'
import {BigNumber, ContractReceipt, Wallet} from "ethers";
import {ethers} from "hardhat";
import {expect} from "chai";
import {
  SimpleWallet,
  SimpleWallet__factory,
  Singleton,
  Singleton__factory,
  TestCounter,
  TestCounter__factory,
  TestUtil,
  TestUtil__factory,
} from "../typechain";
import {
  AddressZero,
  createWalletOwner,
  fund,
  checkForGeth,
  rethrow, tostr, WalletConstructor, calcGasUsage, objdump
} from "./testutils";
import {fillAndSign, ZeroUserOp} from "./UserOp";
import {UserOperation} from "./UserOperation";
import {PopulatedTransaction} from "ethers/lib/ethers";
import exp from "constants";

describe("Singleton", function () {

  let singleton: Singleton
  let singletonView: Singleton

  let testUtil: TestUtil
  let walletOwner: Wallet
  let ethersSigner = ethers.provider.getSigner();
  let wallet: SimpleWallet

  before(async function () {

    await checkForGeth()
    testUtil = await new TestUtil__factory(ethersSigner).deploy()
    singleton = await new Singleton__factory(ethersSigner).deploy(32000)
    //static call must come from address zero, to validate it can only be called off-chain.
    singletonView = singleton.connect(ethers.provider.getSigner(AddressZero))
    walletOwner = createWalletOwner()
    wallet = await new SimpleWallet__factory(ethersSigner).deploy(singleton.address, await walletOwner.getAddress())
    await fund(wallet)
  })

  describe('#simulateWalletValidation', () => {
    const walletOwner1 = createWalletOwner()
    let wallet1: SimpleWallet

    before(async () => {
      wallet1 = await new SimpleWallet__factory(ethersSigner).deploy(singleton.address, await walletOwner1.getAddress())
    })
    it('should fail on-chain', async () => {
      const op = await fillAndSign({target: wallet1.address}, walletOwner1, singleton)
      await expect(singleton.simulateWalletValidation(op)).to.revertedWith('must be called off-chain')
    });
    it('should fail if payForSelfOp fails', async () => {
      //using wrong owner for wallet1
      const op = await fillAndSign({target: wallet1.address}, walletOwner, singleton)
      await expect(singletonView.callStatic.simulateWalletValidation(op).catch(rethrow())).to
        .revertedWith('wrong signature')
    });
    it('should succeed if payForSelfOp succeeds', async () => {
      const op = await fillAndSign({target: wallet1.address}, walletOwner1, singleton)
      await fund(wallet1)
      const ret = await singletonView.callStatic.simulateWalletValidation(op).catch(rethrow())
      console.log('   === simulate result', ret)
    });
    it('should fail creation for wrong target', async () => {
      const op1 = await fillAndSign({
        initCode: WalletConstructor(singleton.address, walletOwner1.address),
        target: '0x'.padEnd(42, '1')
      }, walletOwner1, singleton)
      await expect(singletonView.callStatic.simulateWalletValidation(op1).catch(rethrow()))
        .to.revertedWith('target doesn\'t match create2 address')
    })
    it('should succeed for creating a wallet', async () => {
      const op1 = await fillAndSign({
        initCode: WalletConstructor(singleton.address, walletOwner1.address),
      }, walletOwner1, singleton)
      await fund(op1.target)
      await singletonView.callStatic.simulateWalletValidation(op1).catch(rethrow())
    })
  })

  describe('without paymaster (account pays in eth)', () => {
    describe('#handleOps', () => {
      let counter: TestCounter
      let walletExecFromSingleton: PopulatedTransaction
      before(async () => {

        counter = await new TestCounter__factory(ethersSigner).deploy()
        const count = await counter.populateTransaction.count()
        const execCounterCount = await wallet.populateTransaction.exec(counter.address, count.data!)
        walletExecFromSingleton = await wallet.populateTransaction.execFromSingleton(execCounterCount.data!)
      })

      it('wallet should pay for tx', async function () {

        // await testEthersParam()
        ZeroUserOp.maxFeePerGas = 0
        ZeroUserOp.maxPriorityFeePerGas = 0
        const op = await fillAndSign({
          target: wallet.address,
          callData: walletExecFromSingleton.data,
          verificationGas: 1e6,
          callGas: 1e6
        }, walletOwner)

        const redeemerAddress = Wallet.createRandom().address

        const countBefore = await counter.counters(wallet.address)
        //for estimateGas, must specify maxFeePerGas, otherwise our gas check fails
        console.log('  == est gas=', await singleton.estimateGas.handleOps([op], redeemerAddress, {maxFeePerGas: 1e9}).then(tostr))


        //must specify at least on of maxFeePerGas, gasLimit
        // (gasLimit, to prevent estimateGas to fail on missing maxFeePerGas, see above..)
        const rcpt = await singleton.handleOps([op], redeemerAddress, {
          gasLimit: 1e7
        }).then(t => t.wait())

        const countAfter = await counter.counters(wallet.address)
        expect(countAfter.toNumber()).to.equal(countBefore.toNumber() + 1)
        console.log('rcpt.gasUsed=', rcpt.gasUsed.toString(), rcpt.transactionHash)

        await calcGasUsage(rcpt, singleton, redeemerAddress)

      });

      it('#handleOp (single)', async () => {
        const redeemerAddress = Wallet.createRandom().address

        const op = await fillAndSign({
          target: wallet.address,
          callData: walletExecFromSingleton.data,
        }, walletOwner, singleton)

        const countBefore = await counter.counters(wallet.address)
        const rcpt = await singleton.handleOp(op, redeemerAddress, {
          gasLimit: 1e7
        }).then(t => t.wait())
        const countAfter = await counter.counters(wallet.address)
        expect(countAfter.toNumber()).to.equal(countBefore.toNumber() + 1)

        console.log('rcpt.gasUsed=', rcpt.gasUsed.toString(), rcpt.transactionHash)
        await calcGasUsage(rcpt, singleton, redeemerAddress)

      });
    })

    describe('create account', () => {
      let createOp: UserOperation
      let created = false
      let redeemerAddress = Wallet.createRandom().address //1

      it('should reject create if target address not set', async () => {

        const op = await fillAndSign({
          initCode: WalletConstructor(singleton.address, walletOwner.address),
          verificationGas: 2e6,
          target: '0x'.padEnd(42, '1')
        }, walletOwner, singleton)

        await expect(singleton.handleOps([op], redeemerAddress, {
          gasLimit: 1e7
        })).to.revertedWith('target doesn\'t match create2 address')
      });

      it('should reject create if account not funded', async () => {

        const op = await fillAndSign({
          initCode: WalletConstructor(singleton.address, walletOwner.address),
          verificationGas: 2e6
        }, walletOwner, singleton)

        await expect(singleton.handleOps([op], redeemerAddress, {
          gasLimit: 1e7
        })).to.revertedWith('didn\'t pay prefund')
        await expect(await ethers.provider.getCode(op.target).then(x => x.length)).to.equal(2, "wallet exists before creation")
      });

      it('should succeed to create account after prefund', async () => {

        const preAddr = await singleton.getAccountAddress(WalletConstructor(singleton.address, walletOwner.address), 0)
        await fund(preAddr)
        createOp = await fillAndSign({
          initCode: WalletConstructor(singleton.address, walletOwner.address),
          callGas: 1e7,
          verificationGas: 2e6

        }, walletOwner, singleton)

        await expect(await ethers.provider.getCode(preAddr).then(x => x.length)).to.equal(2, "wallet exists before creation")
        const rcpt = await singleton.handleOps([createOp], redeemerAddress, {
          gasLimit: 1e7,
        }).then(tx => tx.wait()).catch(rethrow())
        created = true
        await calcGasUsage(rcpt!, singleton, redeemerAddress)
      });

      it('should reject if account already created', async function () {
        if (!created) this.skip()
        await expect(singleton.handleOps([createOp], redeemerAddress, {
          gasLimit: 1e7
        })).to.revertedWith('create2 failed')
      });
    })

    describe('batch multiple requests', () => {
      /**
       * attempt a batch:
       * 1. create wallet1 + "initialize" (by calling counter.count())
       * 2. wallet2.exec(counter.count()
       *    (wallet created in advance)
       */
      let counter: TestCounter
      let walletExecCounterFromSingleton: PopulatedTransaction
      const redeemerAddress = Wallet.createRandom().address
      const walletOwner1 = createWalletOwner()
      let wallet1: string
      let walletOwner2 = createWalletOwner()
      let wallet2: SimpleWallet
      let prebalance1: BigNumber
      let prebalance2: BigNumber

      before(async () => {
        counter = await new TestCounter__factory(ethersSigner).deploy()
        const count = await counter.populateTransaction.count()
        const execCounterCount = await wallet.populateTransaction.exec(counter.address, count.data!)
        walletExecCounterFromSingleton = await wallet.populateTransaction.execFromSingleton(execCounterCount.data!)
        wallet1 = await singleton.getAccountAddress(WalletConstructor(singleton.address, walletOwner1.address), 0)
        wallet2 = await new SimpleWallet__factory(ethersSigner).deploy(singleton.address, walletOwner2.address)
        await fund(wallet1)
        await fund(wallet2.address)
        //execute and incremtn counter
        const op1 = await fillAndSign({
          initCode: WalletConstructor(singleton.address, walletOwner1.address),
          callData: walletExecCounterFromSingleton.data,
          callGas: 2e6,
          verificationGas: 2e6
        }, walletOwner1, singleton)

        // console.log('op=', {...op1, callData: op1.callData.length, initCode: op1.initCode.length})

        const op2 = await fillAndSign({
          callData: walletExecCounterFromSingleton.data,
          target: wallet2.address,
          callGas: 2e6,
          verificationGas: 76000,
        }, walletOwner2, singleton)

        const estim = await singletonView.callStatic.simulateWalletValidation(op2, {gasPrice: 1e9})
        const estim1 = await singletonView.simulatePaymasterValidation(op2, estim!, {gasPrice: 1e9})
        const verificationGas = estim.add(estim1.gasUsedByPayForOp)

        await fund(op1.target)
        await fund(wallet2.address)
        prebalance1 = await ethers.provider.getBalance((wallet1))
        prebalance2 = await ethers.provider.getBalance((wallet2.address))
        const ret = await singleton.handleOps([op1!, op2
        ], redeemerAddress).catch((rethrow())).then(r => r!.wait())
        // console.log(ret.events!.map(e=>({ev:e.event, ...objdump(e.args!)})))
      })
      it('should execute', async () => {
        expect(await counter.counters(wallet1)).equal(1)
        expect(await counter.counters(wallet2.address)).equal(1)
      })
      it('should pay for tx', async () => {
        const cost1 = prebalance1.sub(await ethers.provider.getBalance(wallet1))
        const cost2 = prebalance2.sub(await ethers.provider.getBalance(wallet2.address))
        console.log('cost1=', cost1)
        console.log('cost2=', cost2)
      })
    })
    describe('batch of 10 account exec', () => {
      /**
       * attempt big batch.
       */
      let counter: TestCounter
      let walletExecCounterFromSingleton: PopulatedTransaction
      const redeemerAddress = Wallet.createRandom().address

      before(async () => {
        counter = await new TestCounter__factory(ethersSigner).deploy()
        const count = await counter.populateTransaction.count()
        const execCounterCount = await wallet.populateTransaction.exec(counter.address, count.data!)
        walletExecCounterFromSingleton = await wallet.populateTransaction.execFromSingleton(execCounterCount.data!)
      })

      let wallets: { w: string, owner: Wallet }[] = []

      it('batch of create', async () => {

        let ops: UserOperation[] = []
        let count = 0;
        const maxTxGas = 12e6
        let opsGasCollected = 0
        while (++count) {
          const walletOwner1 = createWalletOwner()
          const wallet1 = await singleton.getAccountAddress(WalletConstructor(singleton.address, walletOwner1.address), 0)
          await fund(wallet1, '0.5')
          const op1 = await fillAndSign({
            initCode: WalletConstructor(singleton.address, walletOwner1.address),
            // callData: walletExecCounterFromSingleton.data,
            maxPriorityFeePerGas: 1e9,
            callGas: 1e5,
            verificationGas: 1.3e6
          }, walletOwner1, singleton)
          // requests are the same, so estimate is the same too.
          const estim = await singletonView.callStatic.simulateWalletValidation(op1, {gasPrice: 1e9})
          const estim1 = await singletonView.simulatePaymasterValidation(op1, estim!, {gasPrice: 1e9})
          const verificationGas = estim.add(estim1.gasUsedByPayForOp)
          const txgas = verificationGas.add(op1.callGas).toNumber()

          // console.log('colected so far', opsGasCollected, 'estim', verificationGas, 'max', maxTxGas)
          if (opsGasCollected + txgas > maxTxGas) {
            break;
          }
          opsGasCollected += txgas
          // console.log('== estim=', estim1.gasUsedByPayForOp, estim, verificationGas)
          ops.push(op1)
          wallets.push({owner: walletOwner1, w: wallet1})
        }

        await handleOpsAndStats(ops, count)
      })
      it('batch of tx', async function () {
        if (!wallets.length) {
          this.skip()
        }

        let ops: UserOperation[] = []
        for (let {w, owner} of wallets) {
          const op1 = await fillAndSign({
            target: w,
            callData: walletExecCounterFromSingleton.data,
            callGas: 1e5,
            maxPriorityFeePerGas: 1e9,
            verificationGas: 1.3e6
          }, owner, singleton)
          ops.push(op1)
        }

        await handleOpsAndStats(ops, ops.length)
      })
    })

    async function handleOpsAndStats(ops: UserOperation[], count: number) {
      const redeemerAddress = createWalletOwner().address
      const sender = ethersSigner // ethers.provider.getSigner(5)
      const senderPrebalance = await ethers.provider.getBalance(await sender.getAddress())

      //for slack testing, we set TX priority same as UserOp
      //(real miner may create tx with priorityFee=0, to avoid paying from the "sender" to coinbase)
      const {maxPriorityFeePerGas} = ops[0]
      const ret = await singleton.connect(sender).handleOps(ops, redeemerAddress, {gasLimit: 13e6, maxPriorityFeePerGas}).catch((rethrow())).then(r => r!.wait())

      console.log('actual gas=', ret.gasUsed)
      // console.log(ret.events!.map(e => ({ev: e.event, ...objdump(e.args!)})))

      //note that in theory, each could can have different gasPrice (depends on its prio/max), but in our
      // test they are all the same.
      const {actualGasPrice} = ret.events![0].args!
      const actualGasCost = ret.events!.map(x => x.args!.actualGasCost).reduce((sum, x) => sum.add(x))

      const senderPaid = senderPrebalance.sub(await ethers.provider.getBalance(await sender.getAddress()))
      let senderRedeemed = await ethers.provider.getBalance(redeemerAddress);

      expect(senderRedeemed).to.equal(actualGasCost)
      console.log('gp:', await ethers.provider.getGasPrice())
      console.log('gasPrice:', actualGasPrice)
      console.log('senderPaid=         ', senderPaid)
      console.log('redeemed=           ', senderRedeemed)
      console.log('slack=', (100 - senderPaid.mul(10000).div(senderRedeemed).toNumber() / 100).toFixed(2), '%')
      let payDiff = senderPaid.sub(senderRedeemed).div(count)
      const gasDiff = payDiff.div(actualGasPrice)
      console.log('per-op gas overpaid:', gasDiff.toNumber(), 'singleton perOpOverhead=',await singleton.perOpOverhead())
    }
  })
})
