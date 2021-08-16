import {describe} from 'mocha'
import {ethers} from "hardhat";
import {expect} from "chai";
import {
  IExecutable,
  IExecutable__factory,
  TestExecLib,
  TestExecLib__factory
} from "../typechain";
import {AddressZero} from "./testutils";

describe('#ExecLib', () => {

  let execLib: TestExecLib
  let wallet: IExecutable
  let ethersSigner = ethers.provider.getSigner();
  let func: string
  const destAddr = '0x'.padEnd(42, '1')
  const funcMethodSig = '0xdeadface'
  const funcParams = '0x1234'
  before(async () => {
    execLib = await new TestExecLib__factory(ethersSigner).deploy()
    const wallet = IExecutable__factory.connect(AddressZero, ethersSigner)
    const funcTx = await wallet.populateTransaction.exec(destAddr, funcMethodSig + funcParams.slice(2))
    func = funcTx.data!
  })

  it('#isExec', async () => {
    expect(await execLib.isExec('0x')).to.equal(false)
    expect(await execLib.isExec('0x12')).to.equal(false)
    expect(await execLib.isExec('0x12345678')).to.equal(false)
    expect(await execLib.isExec('0x123456789abcdef0')).to.equal(false)
    expect(await execLib.isExec(func)).to.equal(true)
  })
  it('#decodeExecMethod', async () => {
    const {dest, methodSig, params} = await execLib.decodeExecMethod(func)
    expect(dest).to.equal(destAddr)
    expect(methodSig).to.equal(funcMethodSig)
    expect(params).to.equal(funcParams)
  })
})