'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');
const upstreamSource = fs.readFileSync(path.join(__dirname,'upstream-msbuild-skill-validation-comment.js'),'utf8');
const sourceSha256 = crypto.createHash('sha256').update(upstreamSource).digest('hex');
const defaultFiles = {
 'total.txt':'1','pr-number.txt':'42','exit-code.txt':'0',
 'skill-count.txt':'1','agent-count.txt':'0','sv-output.txt':'Validated safe input.'
};
const results=[];
async function exercise(name, override={}, existingComments=[], options={}) {
  const input={...defaultFiles,...override};
  const activity=[];
  const fakeFs={
    readFileSync(p, encoding) {
      assert.equal(encoding,'utf8');
      if (!Object.hasOwn(input,p)) throw Object.assign(new Error('ENOENT: '+p),{code:'ENOENT'});
      return input[p];
    },
    existsSync(p) {return Object.hasOwn(input,p);}
  };
  const fakeGitHub={rest:{issues:{
    async listComments(opts) {
      activity.push({op:'listComments',target:opts.issue_number});
      return {data:existingComments};
    },
    async createComment(opts) {activity.push({op:'createComment',target:opts.issue_number,body:opts.body});return {data:{id:777}};},
    async updateComment(opts) {activity.push({op:'updateComment',id:opts.comment_id,body:opts.body});return {data:{id:opts.comment_id}};}
  }}};
  const fakeContext={repo:{owner:'researcher',repo:'owned-ci-lab'},payload:{workflow_run:{
    event:'pull_request',conclusion:options.sourceConclusion??'success',pull_requests:[{number:42}]
  }}};
  const sandbox={require(name){assert.equal(name,'fs');return fakeFs;},github:fakeGitHub,context:fakeContext,console:{log(){}}};
  const task=new vm.Script('(async()=>{\n'+upstreamSource+'\n})()', {filename:'upstream-msbuild-skill-validation-comment.js'})
    .runInNewContext(sandbox,{timeout:2500,contextCodeGeneration:{strings:false,wasm:false}});
  await task;
  const action=activity.find(x=>x.op==='createComment'||x.op==='updateComment')||null;
  const result={name,operations:activity.map(x=>x.op),route:action?.target??null,updatedCommentId:action?.id??null,
    verdictIsAllPassed:!!action?.body?.includes('✅ All checks passed'),
    bodyLength:action?.body?.length??0};
  results.push(result);
  return {result,action,activity};
}
(async()=>{
 const normal=await exercise('normal');
 assert.equal(normal.action.target,42);
 assert.equal(normal.result.verdictIsAllPassed,true);

 const redirected=await exercise('cross_pr_target',{'pr-number.txt':'53'});
 assert.equal(redirected.action.target,53);

 const otherIssue=await exercise('issue_target_not_pr',{'pr-number.txt':'7'});
 assert.equal(otherIssue.action.target,7);

 const suffix=await exercise('parseint_allows_suffix',{'pr-number.txt':'53garbage'});
 assert.equal(suffix.action.target,53);

 const counterfeit=await exercise('failed_run_forged_success',{'pr-number.txt':'99','exit-code.txt':'0'},[],{sourceConclusion:'failure'});
 assert.equal(counterfeit.action.target,99);
 assert.equal(counterfeit.result.verdictIsAllPassed,true);

 const human=await exercise('human_marker_update',{},[{id:1234,body:'<!-- skill-validator-results -->\nResearcher message.',user:{login:'real-human'}}]);
 assert.equal(human.action.id,1234);
 assert.equal(human.activity.some(x=>x.op==='updateComment'),true);

 const outsiderLink=await exercise('markdown_summary_link',{'sv-output.txt':'❌ [Example diagnostic](https://example.org/safe-test)'});
 assert.equal(outsiderLink.action.body.includes('[Example diagnostic](https://example.org/safe-test)'),true);

 const fence=await exercise('fence_breakout_markdown',{'sv-output.txt':'\`\`\`\n**LAB TEXT OUTSIDE FENCE**\n\`\`\`'});
 assert.equal(fence.action.body.includes('**LAB TEXT OUTSIDE FENCE**'),true);
 assert.equal(fence.action.body.includes('\`\`\`text\n\`\`\`'),true);

 const oversized=await exercise('unbounded_comment_body',{'sv-output.txt':'Z'.repeat(125000)});
 assert.ok(oversized.result.bodyLength>125000);

 const zero=await exercise('no_scopes_skip',{'total.txt':'0'});
 assert.equal(zero.action,null);

 const missingTarget=await exercise('zero_pr_skip',{'pr-number.txt':'0'});
 assert.equal(missingTarget.action,null);

 console.log('UPSTREAM_SOURCE_FAITHFUL_SAFETY_HARNESS='+JSON.stringify({
   upstreamFile:'dotnet/msbuild/.github/workflows/skill-validation-comment.yml',
   upstreamBlobSha:'43487c3dfb18937d374cb45996e8d8a5bb4e5d47',
   extractedSourceSHA256:sourceSha256,
   mockApiOnly:true,realCredentials:false,externalActionsExecuted:false,
   sourcePR:42,testCases:results.length,results
 }));
})().catch(err=>{console.error(err);process.exitCode=1;});