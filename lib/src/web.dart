const webPage = r'''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Catglobe Developer Tools</title>
<style>
body{font:16px system-ui;background:#f2f5fa;color:#17243d;margin:0}main{max-width:1050px;margin:40px auto;padding:20px}section{background:white;padding:24px;border-radius:14px;margin:20px 0}input,textarea,select,button{font:inherit;padding:10px;border:1px solid #ccd4df;border-radius:6px}input,textarea{width:100%;box-sizing:border-box}textarea{font-family:monospace;resize:vertical}[hidden]{display:none!important}label{display:grid;gap:5px;font-size:14px}#fields{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:15px}#fields label{min-width:0}@media(max-width:760px){#fields{grid-template-columns:1fr}}button{cursor:pointer;background:#174cb4;color:white;margin:8px 5px 8px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#14213a;color:#e5efff;padding:18px;border-radius:8px}p{color:#52617a}.row{display:flex;flex-wrap:wrap;gap:10px;align-items:center}
</style><main><h1>Catglobe Developer Tools</h1><p>Local CGScript • Remote execution • Deployment</p>
<section><h2>Select project</h2><div class="row"><select id="projects"><option value="">Choose a configuration…</option></select><button id="new">Create</button><button id="edit" hidden>Edit</button><button id="delete" hidden>Delete</button></div></section>
<section id="config-panel" hidden><h2>Project configuration</h2><form id="config"><div id="fields"></div><p>The redirect URI follows the CLI port and is read-only. Register this exact URI with your OpenID server.</p><button>Save configuration</button><button type="button" id="cancel">Cancel</button></form></section>
<section id="connection-panel" hidden><h2>Connection and execution</h2><button id="auth">Login</button><label>Test CGScript<textarea id="script" rows="10" spellcheck="false" placeholder="Enter any CGScript to test on the server"></textarea></label><button id="run">Run test script</button><div class="row"><button id="deploy-test">Deploy build to Test</button><button id="deploy-production">Deploy build to Production</button></div><p>Test builds are for review. Production builds are for customers after review. Run flutter build web in your project before deploying.</p></section>
<section><h2>Results</h2><pre id="result">Ready. Select a configuration to get started.</pre></section></main>
<script>
const token='__CSRF__';let configs=[],authenticated=false;
const scriptStorageKey='catglobe_dev.testScript';
const scriptInput=document.querySelector('#script');
try{scriptInput.value=localStorage.getItem(scriptStorageKey)??''}catch(e){console.warn('Unable to restore saved CGScript',e)}
scriptInput.addEventListener('input',()=>{try{localStorage.setItem(scriptStorageKey,scriptInput.value)}catch(e){console.warn('Unable to save CGScript',e)}});
const fields={id:'Configuration ID',name:'Project name',projectPath:'Project folder (absolute path)',issuer:'OpenID issuer',clientId:'Client ID',rootFolderId:'Root folder ID',redirectUri:'Redirect URI',scriptDirectory:'CGScript folder',buildDirectory:'Build output folder'};
const defaults={name:__PROJECT_NAME_JSON__,projectPath:__PROJECT_PATH_JSON__,issuer:'https://voxmeter.catglobe.com/',redirectUri:location.origin+'/auth/callback',scriptDirectory:'cgscript',buildDirectory:'build/web'};
for(const [key,title] of Object.entries(fields)){const label=document.createElement('label');label.textContent=title;const input=document.createElement('input');input.name=key;input.readOnly=key==='redirectUri';input.required=['id','name','projectPath','issuer'].includes(key);label.append(input);document.querySelector('#fields').append(label)}
function fill(config){for(const key of Object.keys(fields))document.forms.config.elements[key].value=key==='redirectUri'?location.origin+'/auth/callback':config[key]||''}
function show(value){document.querySelector('#result').textContent=typeof value==='string'?value:JSON.stringify(value,null,2)}
async function api(path,body){const response=await fetch('/api/'+path,body===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json','X-Cg-Token':token},body:JSON.stringify(body)});const result=await response.json();if(!response.ok){const error=result?.error??response.status;throw Error(typeof error==='string'?error:JSON.stringify(error))}return result}
async function refresh(){const result=await api('configs');configs=result.projects;const select=document.querySelector('#projects');select.replaceChildren(new Option('Choose a configuration…',''));for(const c of configs)select.add(new Option(c.name,c.id));select.value=result.selected||'';authenticated=result.authenticated;document.querySelector('#auth').textContent=authenticated?'Logout':'Login';for(const id of ['edit','delete','connection-panel'])document.getElementById(id).hidden=!result.selected}
function action(id,fn){document.getElementById(id).onclick=async()=>{try{await fn()}catch(e){show(e.message)}}}
function editConfig(config){fill(config);document.querySelector('#config-panel').hidden=false}
action('new',()=>editConfig({...defaults,id:crypto.randomUUID()}));
action('edit',()=>{const config=configs.find(c=>c.id===document.querySelector('#projects').value);if(!config)throw Error('Choose a configuration to edit');editConfig(config)});
action('cancel',()=>{document.querySelector('#config-panel').hidden=true});
document.forms.config.onsubmit=async event=>{event.preventDefault();try{const config=Object.fromEntries(new FormData(event.target));delete config.redirectUri;await api('configs',config);document.querySelector('#config-panel').hidden=true;await refresh();show('Configuration saved')}catch(e){show(e.message)}};
document.querySelector('#projects').onchange=async event=>{const select=event.target;select.disabled=true;document.querySelector('#config-panel').hidden=true;document.querySelector('#connection-panel').hidden=true;try{await api('select',{id:select.value});await refresh()}catch(e){show(e.message);await refresh()}finally{select.disabled=false}};
action('delete',async()=>{const id=document.querySelector('#projects').value;const config=configs.find(c=>c.id===id);if(!config)return;if(confirm('Delete configuration '+config.name+'?')){await api('delete',{id});document.querySelector('#config-panel').hidden=true;await refresh();show('Configuration deleted')}});
action('auth',async()=>{await refresh();if(authenticated){await api('logout',{});await refresh()}else{const result=await api('login',{});location.assign(result.url)}});
action('run',async()=>{const script=document.querySelector('#script').value;if(!script.trim())throw Error('Enter a CGScript to run');show(await api('run',{script}));await refresh()});
for(const mode of ['test','production'])action('deploy-'+mode,async()=>{if(confirm(mode==='production'?'Deploy this build to Production for customers after review?':'Deploy this build to Test for review?'))show(await api('deploy',{kind:'build',mode}));await refresh()});
fill({...defaults,id:crypto.randomUUID()});refresh().catch(e=>show(e.message));
</script></html>''';
