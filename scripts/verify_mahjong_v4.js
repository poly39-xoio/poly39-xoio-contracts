#!/usr/bin/env node
// MahjongMatch v3 → Polygonscan verify(standard-json;與 scripts/compile_mahjong.js 同設定:viaIR + optimizer200, solc 0.8.37)
const fs=require('fs'), path=require('path');
const ROOT=path.resolve(__dirname,'..');
const ADDR=fs.readFileSync(path.join(ROOT,'build/MahjongMatch.v4.address.txt'),'utf8').split('\n')[0].trim();
const env={}; fs.readFileSync('/root/.openclaw/workspace/xoio-v2/.env','utf8').split('\n').forEach(l=>{const m=l.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/i); if(m) env[m[1]]=m[2].replace(/^["']|["']$/g,'');});
const F=(p)=>fs.readFileSync(path.join(ROOT,p),'utf8');
const sources={
 'contracts/mahjong/MahjongMatch.sol': F('contracts/mahjong/MahjongMatch.sol'),
 '@openzeppelin/contracts/token/ERC20/IERC20.sol': F('node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol'),
 '@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol': F('node_modules/@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol'),
 '@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwnerWithProposal.sol': F('node_modules/@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwnerWithProposal.sol'),
 '@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol': F('node_modules/@chainlink/contracts/src/v0.8/shared/interfaces/IOwnable.sol'),
};
const input={language:'Solidity',sources:Object.fromEntries(Object.entries(sources).map(([k,v])=>[k,{content:v}])),
 settings:{optimizer:{enabled:true,runs:200},viaIR:true,outputSelection:{'*':{'*':['abi','evm.bytecode.object','evm.deployedBytecode.object']}}}};
(async()=>{
 const params=new URLSearchParams({chainid:'137',module:'contract',action:'verifysourcecode',
  contractaddress:ADDR, sourceCode:JSON.stringify(input), codeformat:'solidity-standard-json-input',
  contractname:'contracts/mahjong/MahjongMatch.sol:MahjongMatch',
  compilerversion:'v0.8.37+commit.f401782d', optimizationUsed:'1', apikey:env.POLYGONSCAN_API_KEY||''});
 console.log('送驗證:', ADDR, '| sources', Object.keys(sources).length, '| json', JSON.stringify(input).length,'chars');
 const r=await fetch('https://api.etherscan.io/v2/api?chainid=137',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:params});
 const j=await r.json(); console.log('結果:', JSON.stringify(j).slice(0,400));
 if(j.result) fs.writeFileSync('/tmp/mj_verify_guid_v4.txt', String(j.result));
})().catch(e=>{console.error('ERR',e.message.slice(0,300));process.exit(1);});
