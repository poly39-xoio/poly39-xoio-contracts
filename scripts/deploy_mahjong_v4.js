#!/usr/bin/env node
// 部署 MahjongMatch v3(代買版)。owner = 部署者;settler = 同一顆(0xd7f660...)
const fs=require('fs'), path=require('path');
const { ethers } = require('/root/.openclaw/workspace/xoio-v2/node_modules/ethers');
const ROOT=path.resolve(__dirname,'..');
const env={}; fs.readFileSync('/root/.openclaw/workspace/xoio-v2/.env','utf8').split('\n').forEach(l=>{const m=l.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/i); if(m) env[m[1]]=m[2].replace(/^["']|["']$/g,'');});
const abi=JSON.parse(fs.readFileSync(path.join(ROOT,'build/MahjongMatch.abi'),'utf8'));
const bin=fs.readFileSync(path.join(ROOT,'build/MahjongMatch.bin'),'utf8').trim();
(async()=>{
  const p=new ethers.providers.JsonRpcProvider('https://poly39.io/rpc',137);
  const w=new ethers.Wallet(env.PRIVATE_KEY,p);
  console.log('deployer(owner/settler):', w.address, '| POL', Number(ethers.utils.formatEther(await p.getBalance(w.address))).toFixed(3));
  const f=new ethers.ContractFactory(abi, '0x'+bin, w);
  const tip=ethers.utils.parseUnits('30','gwei'), maxf=ethers.utils.parseUnits('350','gwei');
  console.log('deploying...');
  const c=await f.deploy(w.address, {maxPriorityFeePerGas:tip, maxFeePerGas:maxf});
  const tx=c.deployTransaction;
  console.log('🚀 tx', tx.hash);
  await c.deployed();
  const rc=await p.waitForTransaction(tx.hash,1);
  console.log('✅ 部署完成 @', c.address, '| block', rc.blockNumber, '| gasUsed', rc.gasUsed.toString());
  console.log('   owner=', await c.owner(), '| settler=', await c.settler(), '| tableCount=', (await c.tableCount()).toString());
  console.log('   USDT=', await c.USDT_ADDRESS(), '| feeBps=', await c.feeBps(), '| maxTai=', (await c.maxTai()).toString());
  fs.writeFileSync(path.join(ROOT,'build/MahjongMatch.v4.address.txt'), c.address+'\n'+tx.hash+'\n');
  console.log('地址已存 build/MahjongMatch.v4.address.txt');
})().catch(e=>{console.error('ERR', e.message.slice(0,300)); process.exit(1);});
