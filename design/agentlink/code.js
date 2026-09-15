// Local, network-free design generator. Creates new editable frames only.
(async () => {
  const fonts = await figma.listAvailableFontsAsync();
  const candidates = ['PingFang SC', 'Noto Sans CJK SC', 'Noto Sans SC', 'Inter'];
  const family = candidates.find(f => fonts.some(x => x.fontName.family === f));
  const available = fonts.filter(x => x.fontName.family === family);
  const regular = (available.find(x => /Regular|Normal/.test(x.fontName.style)) || available[0]).fontName;
  const strong = (available.find(x => /Semibold|Semi Bold|Medium/.test(x.fontName.style)) || available[0]).fontName;
  await figma.loadFontAsync(regular); await figma.loadFontAsync(strong);
  const C = {bg:'F6F7FB',white:'FFFFFF',ink:'182238',muted:'6D768A',line:'E5E8F0',brand:'5458DC',lav:'EEEDFF',teal:'167C72',mint:'E8F5F0',amber:'96610E',sand:'FFF3D8',red:'B93E4B'};
  const rgb = h => ({r:parseInt(h.slice(0,2),16)/255,g:parseInt(h.slice(2,4),16)/255,b:parseInt(h.slice(4,6),16)/255});
  const fill = h => [{type:'SOLID',color:rgb(h)}];
  const page = figma.createPage(); page.name = '01 · Android 核心页面'; await figma.setCurrentPageAsync(page);
  function box(p,x,y,w,h,c=C.white,r=16,name='Surface') { const n=figma.createFrame();n.name=name;n.resize(w,h);n.x=x;n.y=y;n.fills=fill(c);n.cornerRadius=r;p.appendChild(n);return n; }
  function txt(p,s,x,y,w=340,size=14,c=C.ink,bold=false) {const n=figma.createText();n.fontName=bold?strong:regular;n.fontSize=size;n.lineHeight={unit:'PIXELS',value:Math.round(size*1.5)};n.characters=s;n.fills=fill(c);n.resize(w,Math.max(size*1.5,24));n.textAutoResize='HEIGHT';n.x=x;n.y=y;n.name=s.slice(0,40);p.appendChild(n);return n;}
  function button(p,s,x,y,w=345,primary=true){const n=box(p,x,y,w,52,primary?C.brand:C.white,14,s);if(!primary){n.strokes=fill(C.line);n.strokeWeight=1;}txt(n,s,16,14,w-32,15,primary?C.white:C.ink,true);return n;}
  function badge(p,s,x,y,w,c=C.lav,t=C.brand){const n=box(p,x,y,w,28,c,8,s);txt(n,s,10,5,w-16,11,t,true);return n;}
  function line(p,y){box(p,24,y,345,1,C.line,0,'Divider');}
  function screen(name,i,title,sub){const n=box(page,80+(i%4)*465,180+Math.floor(i/4)*1010,393,852,C.bg,28,name);n.clipsContent=true;txt(n,'9:41',26,16,90,13,C.ink,true);txt(n,'▮▮  Wi-Fi  ▰',280,16,95,11,C.ink);txt(n,title,24,66,345,28,C.ink,true);if(sub)txt(n,sub,24,112,345,13,C.muted);box(n,140,832,113,4,C.ink,2,'Android gesture bar');return n;}
  function nav(p,selected='项目'){box(p,0,754,393,66,C.white,0,'Bottom navigation');['项目','待处理','连接'].forEach((s,i)=>{if(s===selected)box(p,23+i*124,764,100,42,C.lav,14);txt(p,s,48+i*124,774,72,13,s===selected?C.brand:C.muted,s===selected);});}
  const links=[];
  txt(page,'AgentLink',80,24,800,48,C.ink,true);txt(page,'手机里的开发工作台  /  Flutter Android · 393 × 852 · 可编辑页面',82,104,1400,18,C.muted);
  const s0=screen('01 · 安全连接',0,'把开发现场，带在身边','连接电脑上的 HAPI，继续你的开发任务');
  const hero=box(s0,24,170,345,166,C.ink,22);badge(hero,'HOST',24,24,64,C.brand,C.white);txt(hero,'电脑执行\n手机掌握进度',24,64,285,25,C.white,true);txt(s0,'连接你的工作台',24,368,345,19,C.ink,true);txt(s0,'Hub 地址',24,410,345,12,C.muted);box(s0,24,437,345,52,C.white,12);txt(s0,'https://your-hub.example',40,452,305,14,C.muted);txt(s0,'配对凭据',24,510,345,12,C.muted);box(s0,24,537,345,52,C.white,12);txt(s0,'粘贴电脑端提供的凭据',40,552,305,14,C.muted);links.push([button(s0,'连接工作台  →',24,617),1]);txt(s0,'也可粘贴完整配对链接\n凭据保存在设备安全存储中',24,694,345,12,C.muted);
  const s1=screen('02 · 项目工作台',1,'工作台','MacBook Pro  ·  已连接');
  box(s1,24,156,345,48,C.white,14);badge(s1,'Codex',30,162,164,C.brand,C.white);txt(s1,'CodeBuddy',219,171,125,14,C.muted,true);
  const attention=box(s1,24,224,345,100,C.sand,18);badge(attention,'需要你处理',16,14,106,C.white,C.amber);txt(attention,'1 项授权等待确认',16,53,290,18,C.ink,true);links.push([attention,5]);
  txt(s1,'项目',24,352,170,20,C.ink,true);txt(s1,'2 个项目',279,357,90,12,C.muted);
  const project=box(s1,24,394,345,146);badge(project,'AG',16,17,42);txt(project,'AgentLink',72,14,243,18,C.ink,true);txt(project,'~/Projects/agentlink',72,46,243,12,C.muted);line(project,81);txt(project,'●  1 运行中     ◷  1 待审批',16,100,305,13,C.teal);links.push([project,2]);
  const project2=box(s1,24,556,345,115);badge(project2,'DS',16,17,42,C.mint,C.teal);txt(project2,'Design System',72,14,243,18,C.ink,true);txt(project2,'最近活动 · 昨天',72,49,243,12,C.muted);links.push([button(s1,'＋  新建任务',24,688),3]);nav(s1);
  const s2=screen('03 · 项目任务',2,'AgentLink','Codex  /  MacBook Pro');
  badge(s2,'进行中  2',24,158,112,C.brand,C.white);badge(s2,'历史任务  12',148,158,128,C.white,C.muted);
  function task(p,y,title,desc,status,color){const a=box(p,24,y,345,138);badge(a,status,16,15,92,color===C.amber?C.sand:C.mint,color);txt(a,title,16,53,309,17,C.ink,true);txt(a,desc,16,91,309,12,C.muted);return a;}
  links.push([task(s2,211,'完善 Android 连接流程','正在检查配对状态 · 刚刚','运行中',C.teal),4]);links.push([task(s2,365,'补充连接状态测试','运行命令需要你的授权 · 2 分钟前','待审批',C.amber),5]);txt(s2,'继续最近的工作',24,536,345,15,C.muted);const old=task(s2,573,'整理项目文档','会话已结束，可恢复并继续','可继续',C.teal);links.push([old,4]);nav(s2);
  const s3=screen('04 · 新建任务',3,'开始一项任务','选好执行环境，再描述你想完成的工作');
  txt(s3,'使用哪个 Agent',24,165,345,13,C.muted);badge(s3,'Codex  ✓',24,199,162,C.brand,C.white);badge(s3,'CodeBuddy',201,199,168,C.white,C.muted);txt(s3,'执行电脑',24,256,345,13,C.muted);box(s3,24,289,345,62);txt(s3,'●  MacBook Pro',40,307,240,15,C.teal,true);txt(s3,'在线',313,309,45,12,C.muted);txt(s3,'项目目录',24,382,345,13,C.muted);box(s3,24,413,345,58);txt(s3,'~/Projects/agentlink',40,430,313,14);txt(s3,'任务描述',24,502,345,13,C.muted);box(s3,24,536,345,138);txt(s3,'完善 Android 的连接状态页面，\n断网时给出明确的恢复入口。',40,554,305,15);links.push([button(s3,'创建并开始  →',24,715),4]);
  const s4=screen('05 · 对话与执行',4,'完善 Android 连接流程','‹  AgentLink  ·  Codex  ·  在线');
  const user=box(s4,60,164,309,86,C.lav,16);txt(user,'完善连接状态页面，断网时给出\n明确的恢复入口。',16,16,277,14);
  badge(s4,'CX',24,278,38,C.ink,C.white);txt(s4,'Codex',74,282,230,14,C.ink,true);txt(s4,'我会先检查连接状态和重试逻辑，\n再补充对应的页面状态。',24,325,345,15);
  const tool=box(s4,24,397,345,102,C.white,14);badge(tool,'✓  已读取',16,14,95,C.mint,C.teal);txt(tool,'lib/app_model.dart',16,54,280,14,C.ink,true);txt(s4,'正在梳理断网后的消息处理…',24,528,345,15);badge(s4,'●  正在执行',24,583,115,C.mint,C.teal);button(s4,'停止',281,575,88,false);
  box(s4,16,672,361,136,C.white,20);txt(s4,'补充需求，或继续提问…',32,692,312,15,C.muted);badge(s4,'Codex',32,752,80);button(s4,'发送 ↑',269,740,92);txt(s4,'任务菜单：重命名 · 查看更早消息',24,635,345,11,C.muted);
  const s5=screen('06 · 有效审批',5,'确认这次操作','AgentLink  /  Codex');badge(s5,'等待你的授权',24,158,132,C.sand,C.amber);txt(s5,'运行项目测试',24,214,345,24,C.ink,true);txt(s5,'Agent 请求在电脑上运行以下命令。\n确认后仅授权本次操作。',24,260,345,14,C.muted);
  const command=box(s5,24,329,345,162,C.ink,16);txt(command,'COMMAND',16,16,305,11,'A8B1C5',true);txt(command,'flutter test',16,52,305,18,C.white,true);txt(command,'工作目录\n/Users/dev/Projects/agentlink/flutter',16,99,305,12,'C9D0DF');txt(s5,'由 MacBook Pro 执行',24,522,345,14,C.ink,true);txt(s5,'完整参数  ›',24,562,345,13,C.brand);box(s5,24,608,345,53,C.sand,12);txt(s5,'若请求已失效，系统会阻止继续授权。',38,624,315,12,C.amber);links.push([button(s5,'允许一次',24,687,217),4]);button(s5,'拒绝',253,687,116,false);txt(s5,'提交后等待电脑确认，未确认前不显示成功',24,762,345,11,C.muted);
  const s6=screen('07 · 回答 Agent',6,'需要你的选择','AgentLink  /  CodeBuddy');badge(s6,'等待回答',24,158,102,C.sand,C.amber);txt(s6,'断网时如何处理输入？',24,219,345,23,C.ink,true);txt(s6,'请选择一个方案，也可以补充具体要求。',24,263,345,14,C.muted);box(s6,24,320,345,86,C.lav,16);txt(s6,'◉  保留草稿，恢复后手动发送',40,338,310,15,C.brand,true);txt(s6,'用户可以确认内容后再继续',66,372,278,12,C.muted);box(s6,24,421,345,68);txt(s6,'○  暂停输入并提示重连',40,444,310,15);txt(s6,'补充说明（可选）',24,529,345,13,C.muted);box(s6,24,562,345,95);txt(s6,'不要在重连后自动重复发送',40,581,308,14);links.push([button(s6,'提交回答',24,713),4]);
  const s7=screen('08 · 断线与重试',7,'连接与恢复','保留当前工作，连接恢复后继续');badge(s7,'连接已中断',24,157,128,C.sand,C.amber);const host=box(s7,24,214,345,117);txt(host,'MacBook Pro',16,18,310,18,C.ink,true);txt(host,'无法连接当前 Hub\n上次同步 · 2 分钟前',16,53,310,13,C.muted);button(s7,'重新连接',24,354);txt(s7,'待发送消息',24,453,345,20,C.ink,true);box(s7,24,501,345,142);txt(s7,'完善 Android 连接流程',40,518,310,15,C.ink,true);txt(s7,'发送结果尚未确认，内容已保留。\n重试会沿用同一请求，避免重复任务。',40,558,309,13,C.muted);button(s7,'重试发送',24,669,217);button(s7,'查看会话',253,669,116,false);nav(s7,'连接');
  const screens=[s0,s1,s2,s3,s4,s5,s6,s7];
  for(const [source,target] of links) await source.setReactionsAsync([{trigger:{type:'ON_CLICK'},actions:[{type:'NODE',destinationId:screens[target].id,navigation:'NAVIGATE',transition:{type:'DISSOLVE',duration:0.2,easing:{type:'EASE_OUT'}}}]}]);
  txt(page,'设计说明',80,2250,700,30,C.ink,true);txt(page,'真实能力：Host 管理的 Codex / CodeBuddy 会话、项目分组、对话、一次授权、提问、恢复与重试。\n待处理聚合入口属于界面提案；不包含接管现有 IDE 全部会话、文件 diff、附件、云机器或推送承诺。\n所有内容均为示例数据。审批必须以 Host 的权威结果为准。',80,2310,1750,18,C.muted);
  figma.viewport.scrollAndZoomIntoView(screens.slice(0,4));
  figma.closePlugin('已创建 8 个可编辑页面及主要流程连线');
})().catch(e=>figma.closePlugin(String(e)));
