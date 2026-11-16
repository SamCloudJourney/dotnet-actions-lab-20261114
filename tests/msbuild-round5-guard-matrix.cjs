'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto'),fs=require('node:fs'),path=require('node:path');
const BT=String.fromCharCode(96);
const src=fs.readFileSync(path.join(__dirname,'upstream-msbuild-skill-validation-comment.js'),'utf8');
assert.ok(src.includes("parseInt(fs.readFileSync('pr-number.txt'"));
assert.ok(src.includes("const existing = comments.find(c => c.body.includes(marker))"));
const marker='<!-- skill-validator-results -->';
const base={
  run:{event:'pull_request',workflowName:'Skill Validation',repository:'SamCloudJourney/dotnet-actions-lab-20261114',sourceRepository:'SamCloudJourney/dotnet-actions-lab-20261114',conclusion:'success',trustedPR:42},
  artifact:{prNumber:'42',exitCode:'0',output:'one harmless line'},
  issue:{number:42,isPR:true},comments:[]
};
function guarded(x) {
  const r=x.run,a=x.artifact,t=x.issue;
  const reject=reason=>({kind:'reject',reason});
  if(r.event!=='pull_request')return reject('non_pr_event');
  if(r.workflowName!=='Skill Validation')return reject('unexpected_workflow');
  if(r.repository!=='SamCloudJourney/dotnet-actions-lab-20261114')return reject('untrusted_repository');
  if(!r.sourceRepository)return reject('missing_origin');
  if(!Number.isSafeInteger(r.trustedPR)||r.trustedPR<=0)return reject('no_verified_source_pr');
  if(!/^[1-9][0-9]*$/.test(a.prNumber.trim()))return reject('noncanonical_pr_number');
  const pr=Number(a.prNumber.trim());
  if(!Number.isSafeInteger(pr))return reject('out_of_range_pr_number');
  if(pr!==r.trustedPR)return reject('cross_target_pr');
  if(!t.isPR||t.number!==pr)return reject('not_verified_pull_request');
  if(!['success','failure','cancelled','timed_out'].includes(r.conclusion))return reject('unknown_source_conclusion');
  const humanMarker=(x.comments||[]).find(c=>c.body.includes(marker)&&c.user?.login!=='github-actions[bot]');
  const existingBot=(x.comments||[]).find(c=>c.body.includes(marker)&&c.user?.login==='github-actions[bot]');
  const output=(a.output||'').slice(0,32768),limited=(a.output||'').length>32768;
  const escaped=output.slice(0,2048).split('\n').slice(0,10).map(s=>s.replace(/([\\|<>\[\]()*_])/g,'\\$1')).join('\n');
  const seq=output.match(new RegExp(BT+'+','g'))||[];
  const fence=BT.repeat(Math.max(3,...seq.map(s=>s.length+1)));
  const sourceFailure=r.conclusion!=='success';
  const validGreen=a.exitCode==='0'&&!sourceFailure;
  const body=[marker,'LAB ONLY - proposed hardened CI reporting logic',validGreen?'All checks passed':'Validation failed or could not complete','Source run: '+r.conclusion,escaped,fence,output,fence,limited?'Output truncated':''].join('\n');
  return {kind:existingBot?'update_bot_comment':'create_comment',target:pr,existingBotCommentId:existingBot?.id||null,humanMarkerPreserved:!!humanMarker,sourceFailure,validGreen,limited,body};
}
function exercise(name,override={},kind,reason) {
  const x=structuredClone(base);
  for(const k of ['run','artifact','issue'])if(override[k])Object.assign(x[k],override[k]);
  if(override.comments)x.comments=override.comments;
  const r=guarded(x);
  assert.equal(r.kind,kind,name+' kind');
  if(reason)assert.equal(r.reason,reason,name+' reason');
  console.log('ROUND5_GUARD_CASE='+JSON.stringify({name,kind:r.kind,reason:r.reason||'accepted',target:r.target||null,validGreen:r.validGreen??false,humanMarkerPreserved:r.humanMarkerPreserved??false,limited:r.limited??false}));
  return r;
}
exercise('valid_own_pr',{},'create_comment');
exercise('cross_pr',{artifact:{prNumber:'99'}},'reject','cross_target_pr');
exercise('issue_not_pr',{issue:{isPR:false}},'reject','not_verified_pull_request');
exercise('suffix_ignored_by_original_parseint',{artifact:{prNumber:'42garbage'}},'reject','noncanonical_pr_number');
exercise('leading_zeros',{artifact:{prNumber:'0042'}},'reject','noncanonical_pr_number');
exercise('negative_pr',{artifact:{prNumber:'-42'}},'reject','noncanonical_pr_number');
exercise('no_trusted_pr',{run:{trustedPR:undefined}},'reject','no_verified_source_pr');
exercise('wrong_workflow',{run:{workflowName:'Some workflow'}},'reject','unexpected_workflow');
exercise('non_pr_event',{run:{event:'push'}},'reject','non_pr_event');
exercise('wrong_repository',{run:{repository:'attacker/repo'}},'reject','untrusted_repository');
const failed=exercise('failed_run_forged_green',{run:{conclusion:'failure'},artifact:{exitCode:'0'}},'create_comment');
assert.equal(failed.validGreen,false);
const human=exercise('human_marker_preserved',{comments:[{id:555,body:marker,user:{login:'human'}}]},'create_comment');
assert.equal(human.humanMarkerPreserved,true);
const bot=exercise('bot_marker_update',{comments:[{id:556,body:marker,user:{login:'github-actions[bot]'}}]},'update_bot_comment');
assert.equal(bot.existingBotCommentId,556);
const md=exercise('markdown_escaped',{artifact:{output:'[neutral label](https://example.invalid) | TEST'}},'create_comment');
assert.ok(md.body.includes('\\[neutral label\\]'));
assert.ok(md.body.includes('\\|'));
const fences=exercise('fence_containment',{artifact:{output:BT.repeat(3)+'\nLAB ONLY\n'+BT.repeat(3)}},'create_comment');
assert.ok(fences.body.includes(BT.repeat(4)+'\n'+BT.repeat(3)));
const oversized=exercise('output_length_limit',{artifact:{output:'Z'.repeat(250000)}},'create_comment');
assert.equal(oversized.limited,true);assert.ok(oversized.body.length<40000);
console.log('ROUND5_UPSTREAM_GUARD_REGRESSION_ALL_PASSED=true cases=16 baselineSourceSha256='+crypto.createHash('sha256').update(src).digest('hex'));
