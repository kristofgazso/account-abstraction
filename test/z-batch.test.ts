import './aa.init'
import {describe} from 'mocha'
import {Wallet} from "ethers";
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
  rethrow, WalletConstructor, tonumber, callDataCost
} from "./testutils";
import {fillAndSign, packUserOp} from "./UserOp";
import {UserOperation} from "./UserOperation";
import {PopulatedTransaction} from "ethers/lib/ethers";
import {ethers} from 'hardhat'
import {toBuffer} from "ethereumjs-util";
import {defaultAbiCoder} from "ethers/lib/utils";

describe("Batch gas testing", function () {

  let ethersSigner = ethers.provider.getSigner();
  let singleton: Singleton
  let singletonView: Singleton

  let testUtil: TestUtil
  let walletOwner: Wallet
  let wallet: SimpleWallet

  let results: (() => void)[] = []
  before(async function () {

    await checkForGeth()
    testUtil = await new TestUtil__factory(ethersSigner).deploy()
    singleton = await new Singleton__factory(ethersSigner).deploy(22000, 0)
    //static call must come from address zero, to validate it can only be called off-chain.
    singletonView = singleton.connect(ethers.provider.getSigner(AddressZero))
    walletOwner = createWalletOwner()
    wallet = await new SimpleWallet__factory(ethersSigner).deploy(singleton.address, await walletOwner.getAddress())
    await fund(wallet)
  })

  after(async () => {

    console.log('== Summary')
    console.log('note: negative "overpaid" means the client should compensate the relayer with higher priority fee')
    for (let result of results) {
      await result()
    }
  })

  ;[1,
    10
  ].forEach(maxCount => {

    describe('test batches maxCount=' + maxCount, () => {
      /**
       * attempt big batch.
       */
      let counter: TestCounter
      let walletExecCounterFromSingleton: PopulatedTransaction
      let execCounterCount: PopulatedTransaction
      const redeemerAddress = Wallet.createRandom().address

      before(async () => {
        counter = await new TestCounter__factory(ethersSigner).deploy()
        const count = await counter.populateTransaction.count()
        execCounterCount = await wallet.populateTransaction.exec(counter.address, count.data!)
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
          if (wallets.length >= maxCount) break
        }

        await call_handleOps_and_stats('Create', ops, count)
      })

      it('batch of tx', async function () {
        this.timeout(30000)
        if (!wallets.length) {
          this.skip()
        }

        let ops: UserOperation[] = []
        for (let {w, owner} of wallets) {
          const op1 = await fillAndSign({
            target: w,
            callData: walletExecCounterFromSingleton.data,
            maxPriorityFeePerGas: 1e9,
            verificationGas: 1.3e6
          }, owner, singleton)
          ops.push(op1)

          if (once) {
            once = false
            console.log('direct call:', await counter.estimateGas.count())
            console.log('through wallet:', await ethers.provider.estimateGas({
              from: walletOwner.address,
              to: wallet.address,
              data: execCounterCount.data!
            }), 'datacost=', callDataCost(execCounterCount.data!));
            console.log('through handleOps:', await singleton.estimateGas.handleOps([op1], redeemerAddress))
            console.log('through single handleOp:', await singleton.estimateGas.handleOp(op1, redeemerAddress))
          }

        }

        await call_handleOps_and_stats("Simple Ops", ops, ops.length)
      })

      it('batch of expensive ops', async function () {
        this.timeout(30000)
        if (!wallets.length) {
          this.skip()
        }

        let walletExecFromSingleton_waster: PopulatedTransaction
        const waster = await counter.populateTransaction.gasWaster(40, "")
        const execCounter_wasteGas = await wallet.populateTransaction.exec(counter.address, waster.data!)
        walletExecFromSingleton_waster = await wallet.populateTransaction.execFromSingleton(execCounter_wasteGas.data!)

        let ops: UserOperation[] = []
        for (let {w, owner} of wallets) {
          const op1 = await fillAndSign({
            target: w,
            callData: walletExecFromSingleton_waster.data,
            maxPriorityFeePerGas: 1e9,
            verificationGas: 1.3e6
          }, owner, singleton)
          ops.push(op1)
        }

        await call_handleOps_and_stats("Expensive Ops", ops, ops.length)
      })

      it('batch of large ops', async function () {
        this.timeout(30000)
        if (!wallets.length) {
          this.skip()
        }

        let walletExecFromSingleton_waster: PopulatedTransaction
        const waster = await counter.populateTransaction.gasWaster(0, '1'.repeat(16384))
        const execCounter_wasteGas = await wallet.populateTransaction.exec(counter.address, waster.data!)
        walletExecFromSingleton_waster = await wallet.populateTransaction.execFromSingleton(execCounter_wasteGas.data!)

        let ops: UserOperation[] = []
        for (let {w, owner} of wallets) {
          const op1 = await fillAndSign({
            target: w,
            callData: walletExecFromSingleton_waster.data,
            maxPriorityFeePerGas: 1e9,
            verificationGas: 1.3e6
          }, owner, singleton)
          ops.push(op1)
        }

        await call_handleOps_and_stats('Large (16k) Ops', ops, ops.length)
      })

    })
  })

  async function call_handleOps_and_stats(title: string, ops: UserOperation[], count: number) {
    const redeemerAddress = createWalletOwner().address
    const sender = ethersSigner // ethers.provider.getSigner(5)
    const senderPrebalance = await ethers.provider.getBalance(await sender.getAddress())

    const entireTxEncoded = toBuffer(await singleton.populateTransaction.handleOps(ops, redeemerAddress).then(tx => tx.data))

    function callDataCost(data: Buffer | string): number {
      if (typeof data == 'string') {
        data = toBuffer(data)
      }
      return data.map(b => b == 0 ? 4 : 16).reduce((sum, b) => sum + b)
    }

    //data cost of entire bundle
    const entireTxDataCost = callDataCost(entireTxEncoded)
    //the 'handleOp' function has "userOp" as first parameter..
    const type = Object.values(singleton.interface.functions).find(f => f.name == 'handleOp')!.inputs[0]
    const opEncoded = defaultAbiCoder.encode([type], [ops[0]])
    // defaultAbiCoder.encode([opEncoding], [ops[0]])
    const opDataCost = callDataCost(opEncoded)
    console.log('== entire tx data cost=', entireTxDataCost, 'len=', entireTxEncoded.length, 'op data cost=', opDataCost, 'len=',opEncoded.length / 2)
    console.log('== per-op overhead:', entireTxDataCost-(opDataCost*count), 'count=', count)

    //for slack testing, we set TX priority same as UserOp
    //(real miner may create tx with priorityFee=0, to avoid paying from the "sender" to coinbase)
    const {maxPriorityFeePerGas} = ops[0]
    const ret = await singleton.connect(sender).handleOps(ops, redeemerAddress, {
      gasLimit: 13e6,
      maxPriorityFeePerGas
    }).catch((rethrow())).then(r => r!.wait())

    // const allocatedGas = ops.map(op => parseInt(op.callGas.toString()) + parseInt(op.verificationGas.toString())).reduce((sum, x) => sum + x)
    // console.log('total allocated gas (callGas+verificationGas):', allocatedGas)

    //remove "revert reason" events
    const events1 = ret.events!.filter(e => e.event == 'UserOperationEvent')!
    // console.log(events1.map(e => ({ev: e.event, ...objdump(e.args!)})))

    if (events1.length != ret.events!.length) {
      console.log('== reverted: ', ret.events!.length - events1.length)
    }
    //note that in theory, each could can have different gasPrice (depends on its prio/max), but in our
    // test they are all the same.
    const {actualGasPrice} = events1[0]!.args!
    const totalEventsGasCost = parseInt(events1.map(x => x.args!.actualGasCost).reduce((sum, x) => sum.add(x)).toString())

    const senderPaid = parseInt(senderPrebalance.sub(await ethers.provider.getBalance(await sender.getAddress())).toString())
    let senderRedeemed = await ethers.provider.getBalance(redeemerAddress).then(tonumber)

    expect(senderRedeemed).to.equal(totalEventsGasCost)

    //for slack calculations, add the calldataoverhead. should be part of the relayer fee.
    senderRedeemed += entireTxDataCost * actualGasPrice
    console.log('provider gasprice:', await ethers.provider.getGasPrice())
    console.log('userop   gasPrice:', actualGasPrice)
    const opGasUsed = Math.floor(senderPaid / actualGasPrice / count)
    const opGasPaid = Math.floor(senderRedeemed / actualGasPrice / count)
    console.log('senderPaid= ', senderPaid, '(wei)\t', (senderPaid / actualGasPrice).toFixed(0), '(gas)', opGasUsed, '(gas/op)', count)
    console.log('redeemed=   ', senderRedeemed, '(wei)\t', (senderRedeemed / actualGasPrice).toFixed(0), '(gas)', opGasPaid, '(gas/op)')

    // console.log('slack=', ((senderRedeemed - senderPaid) * 100 / senderPaid).toFixed(2), '%', opGasUsed - opGasPaid)
    const dumpResult = async () => {
      console.log('==>', `${title} (count=${count}) : `.padEnd(30), 'per-op gas overpaid:', opGasPaid - opGasUsed, 'singleton perOpOverhead=', await singleton.perOpOverhead().then(tonumber))
    }
    await dumpResult()
    results.push(dumpResult)
  }
})

let once = true
