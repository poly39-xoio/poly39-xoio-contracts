#!/usr/bin/env node
// 編譯 contracts/mahjong/MahjongMatch.sol → build/MahjongMatch.abi|bin(0.8.x + viaIR)
const fs=require('fs'), path=require('path');
const solc=require('solc');
const ROOT=path.resolve(__dirname,'..');
const entry='contracts/mahjong/MahjongMatch.sol';
const source=fs.readFileSync(path.join(ROOT,entry),'utf8');
const findImport=(p)=>{for(const c of [path.join(ROOT,'node_modules',p),path.join(ROOT,p)]) if(fs.existsSync(c)) return {contents:fs.readFileSync(c,'utf8')}; return {error:'not found: '+p};};
const input={language:'Solidity',sources:{[entry]:{content:source}},settings:{optimizer:{enabled:true,runs:200},viaIR:true,outputSelection:{'*':{'*':['abi','evm.bytecode.object']}}}};
const out=JSON.parse(solc.compile(JSON.stringify(input),{import:findImport}));
const errs=(out.errors||[]).filter(e=>e.severity==='error');
const warns=(out.errors||[]).filter(e=>e.severity!=='error');
warns.slice(0,8).forEach(e=>console.log('warn:', e.formattedMessage.split('\n')[0]));
if(errs.length){errs.forEach(e=>console.log('ERROR:',e.formattedMessage));console.log('❌ 編譯失敗 errors='+errs.length);process.exit(1);}
const c=out.contracts[entry]['MahjongMatch'];
fs.mkdirSync(path.join(ROOT,'build'),{recursive:true});
fs.writeFileSync(path.join(ROOT,'build/MahjongMatch.abi'), JSON.stringify(c.abi,null,2));
fs.writeFileSync(path.join(ROOT,'build/MahjongMatch.bin'), c.evm.bytecode.object);
console.log('✅ 編譯通過 | solc '+solc.version().replace('v','') +' | bytecode '+(c.evm.bytecode.object.length/2)+' bytes | abi '+c.abi.length+' | warnings '+warns.length);
