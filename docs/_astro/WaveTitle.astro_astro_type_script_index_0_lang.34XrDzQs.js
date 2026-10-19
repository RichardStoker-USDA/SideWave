var e=null;document.addEventListener(`astro:page-load`,()=>{if(window.matchMedia(`(prefers-reduced-motion: reduce)`).matches||!document.getElementById(`wave-canvas`))return;let n=window.innerWidth<768;requestAnimationFrame(()=>requestAnimationFrame(()=>{t(n).then(t=>{e=t})}))}),document.addEventListener(`astro:before-swap`,()=>{try{e?.()}catch{}e=null});async function t(e){let t=document.getElementById(`wave-canvas`),i=document.getElementById(`hero-title`),o=document.querySelector(`.hero-title-wrap`),s=o?.closest(`section`)??o;if(!t||!i||!o||!s)return null;let c=Math.min(window.devicePixelRatio||1,2),l={time:0,pointerX:.5,excite:0,damp:1,dark:+(document.documentElement.getAttribute(`data-theme`)===`dark`),w:0,h:0},u=document.createElement(`canvas`),d=u.getContext(`2d`);function f(){let e=getComputedStyle(i),n=parseFloat(e.fontSize),r=e.fontWeight,a=e.fontFamily,o=e.letterSpacing===`normal`?0:parseFloat(e.letterSpacing);d.font=`${r} ${n}px ${a}`,o&&(d.letterSpacing=e.letterSpacing);let s=d.measureText(`SideWave`),f=Math.ceil(s.width),p=Math.ceil((s.actualBoundingBoxAscent||n*.72)+(s.actualBoundingBoxDescent||n*.24)),m=f+Math.round(n*.12)*2,h=Math.round(p*1.9);t.style.width=m+`px`,t.style.height=h+`px`,t.width=Math.floor(m*c),t.height=Math.floor(h*c),l.w=t.width,l.h=t.height,u.width=t.width,u.height=t.height,d.setTransform(c,0,0,c,0,0),d.clearRect(0,0,m,h),d.font=`${r} ${n}px ${a}`,o&&(d.letterSpacing=e.letterSpacing),d.textAlign=`center`,d.textBaseline=`middle`,d.fillStyle=`#fff`,d.fillText(`SideWave`,m/2,h/2)}f();let p=null;try{navigator.gpu&&(p=await a(t,u,l))}catch{p=null}if(!p)try{p=r(t,u,l)}catch{p=null}if(!p)return null;i.classList.add(`gl-live`),t.classList.add(`is-live`);let m=.5,h=performance.now(),g=e=>{let n=t.getBoundingClientRect(),r=(e.clientX-n.left)/Math.max(n.width,1);l.pointerX=Math.max(0,Math.min(1,r));let i=performance.now(),a=Math.max(i-h,1),o=Math.abs(l.pointerX-m)/(a/1e3);l.excite=Math.min(1,l.excite+o*.35),m=l.pointerX,h=i};s.addEventListener(`pointermove`,g,{passive:!0});let _=()=>{let e=window.scrollY||0;l.damp=Math.max(0,Math.min(1,1-e/(window.innerHeight*.7)))};window.addEventListener(`scroll`,_,{passive:!0}),_();let v=new MutationObserver(()=>{l.dark=+(document.documentElement.getAttribute(`data-theme`)===`dark`)});v.observe(document.documentElement,{attributes:!0,attributeFilter:[`data-theme`]});let y,b=()=>{clearTimeout(y),y=window.setTimeout(()=>{f(),p.resize()},160)};window.addEventListener(`resize`,b,{passive:!0}),document.fonts?.ready&&document.fonts.ready.then(()=>{f(),p.resize()});let x=0,S=!1,C=performance.now(),w=e=>{let t=Math.min((e-C)/1e3,.05);C=e,l.time+=t,l.excite*=.94,p.render(),x=requestAnimationFrame(w)},T=()=>{S||(S=!0,C=performance.now(),x=requestAnimationFrame(w))},E=()=>{S&&(S=!1,cancelAnimationFrame(x))},D=new IntersectionObserver(([e])=>{e.isIntersecting?T():E()},{threshold:0});D.observe(s);let O=()=>{document.hidden?E():n(s)&&T()};return document.addEventListener(`visibilitychange`,O),()=>{E(),D.disconnect(),v.disconnect(),s.removeEventListener(`pointermove`,g),window.removeEventListener(`scroll`,_),window.removeEventListener(`resize`,b),document.removeEventListener(`visibilitychange`,O),p.dispose()}}function n(e){let t=e.getBoundingClientRect();return t.bottom>0&&t.top<window.innerHeight}function r(e,t,n){let r=e.getContext(`webgl2`,{alpha:!0,premultipliedAlpha:!0,antialias:!0});if(!r)return null;let a=i(r,`#version 300 es
    in vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }`,`#version 300 es
    precision highp float;
    uniform sampler2D uMask;
    uniform vec2 uRes;
    uniform float uTime, uPointer, uExcite, uDamp, uDark;
    out vec4 o;
    
  vec3 spec3(float t){
    t = clamp(t, 0.0, 1.0);
    vec3 c0=vec3(1.000,0.231,0.188), c1=vec3(1.000,0.584,0.000), c2=vec3(1.000,0.800,0.000);
    vec3 c3=vec3(0.204,0.780,0.349), c4=vec3(0.196,0.678,0.902), c5=vec3(0.000,0.478,1.000), c6=vec3(0.686,0.322,0.871);
    float x=t*6.0;
    if(x<1.0) return mix(c0,c1,x);
    else if(x<2.0) return mix(c1,c2,x-1.0);
    else if(x<3.0) return mix(c2,c3,x-2.0);
    else if(x<4.0) return mix(c3,c4,x-3.0);
    else if(x<5.0) return mix(c4,c5,x-4.0);
    return mix(c5,c6,x-5.0);
  }
    void main(){
      vec2 uv = gl_FragCoord.xy / uRes;
      float x = uv.x;
      float pd = x - uPointer;
      float bump = exp(-pd*pd/0.02) * uExcite;
      float env = pow(sin(3.14159265*clamp(x,0.0,1.0)), 1.3);
      float idle = 0.85 + 0.15*sin(uTime*0.7);
      float spec = 0.0; vec3 col = vec3(0.0); float disp = 0.0;
      float best = 0.0; vec3 bestCol = vec3(0.0);
      for(int i=0;i<5;i++){
        float fi=float(i);
        float freq=1.4+fi*0.42; float speed=1.1+fi*0.22;
        float amp=(0.30-fi*0.035);
        float phase=uTime*speed+fi*0.9;
        float a=amp*env*uDamp*(idle+bump*1.6);
        float cy=0.5+sin(6.2831853*freq*x+phase)*a;
        disp+=(cy-0.5);
        float d=uv.y-cy;
        float thick=0.012+fi*0.002;
        float core=1.0 - smoothstep(0.0, thick, abs(d));
        float glow=exp(-(d*d)/(0.010+0.006*fi));
        float hue=fract(x+fi/5.0+uTime*0.05);
        vec3 rc=spec3(hue);
        float inten=core+glow*0.5;
        col+=rc*inten; spec+=inten;
        float band=1.0 - smoothstep(0.0, thick*1.6, abs(d));
        if(band>best){ best=band; bestCol=rc; }
      }
      float refr=disp*0.010;
      float m=texture(uMask, vec2(uv.x+refr, 1.0-uv.y)).a;
      // One design, two exposures. Dark: silver letterforms, strands glow
      // through and spill light onto the surround. Light: ink letterforms,
      // the same strands stream through them and cast a soft pastel wash.
      vec3 baseD=vec3(0.42,0.43,0.47);
      vec3 baseL=vec3(0.155,0.150,0.140);
      // Dark adds the strands' light to silver letters. Light paints only the nearest strand's own
      // color over the ink, so overlapping halos don't muddy the letters.
      vec3 insideD=clamp(baseD+col*1.15,0.0,1.4);
      vec3 insideL=mix(baseL,bestCol,best*0.95);
      vec3 inside=mix(insideL,insideD,uDark);
      // Soft falloff toward every canvas edge so escaping light dies out
      // in air instead of slamming into the rectangle boundary.
      float vign=smoothstep(0.0,0.10,x)*smoothstep(0.0,0.10,1.0-x)
               *smoothstep(0.0,0.24,uv.y)*smoothstep(0.0,0.24,1.0-uv.y);
      float ambient=clamp(spec*0.42,0.0,1.0)*uDamp*mix(0.30,1.0,uDark)*vign;
      float insideA=m;
      float outsideA=ambient*(1.0-m);
      float outA=insideA+outsideA*(1.0-insideA);
      vec3 outC=(inside*insideA+col*outsideA*(1.0-insideA))/max(outA,0.001);
      o=vec4(outC*outA, outA);
    }`);if(!a)return null;r.useProgram(a);let o=r.createBuffer();r.bindBuffer(r.ARRAY_BUFFER,o),r.bufferData(r.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),r.STATIC_DRAW);let s=r.getAttribLocation(a,`p`);r.enableVertexAttribArray(s),r.vertexAttribPointer(s,2,r.FLOAT,!1,0,0);let c=r.createTexture(),l=()=>{r.bindTexture(r.TEXTURE_2D,c),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_MIN_FILTER,r.LINEAR),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_MAG_FILTER,r.LINEAR),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_WRAP_S,r.CLAMP_TO_EDGE),r.texParameteri(r.TEXTURE_2D,r.TEXTURE_WRAP_T,r.CLAMP_TO_EDGE),r.texImage2D(r.TEXTURE_2D,0,r.RGBA,r.RGBA,r.UNSIGNED_BYTE,t)};l();let u=r.getUniformLocation(a,`uMask`),d=r.getUniformLocation(a,`uRes`),f=r.getUniformLocation(a,`uTime`),p=r.getUniformLocation(a,`uPointer`),m=r.getUniformLocation(a,`uExcite`),h=r.getUniformLocation(a,`uDamp`),g=r.getUniformLocation(a,`uDark`);r.enable(r.BLEND),r.blendFunc(r.ONE,r.ONE_MINUS_SRC_ALPHA);let _=()=>{r.viewport(0,0,e.width,e.height),l()};_();let v=()=>{r.viewport(0,0,e.width,e.height),r.clearColor(0,0,0,0),r.clear(r.COLOR_BUFFER_BIT),r.useProgram(a),r.uniform1i(u,0),r.activeTexture(r.TEXTURE0),r.bindTexture(r.TEXTURE_2D,c),r.uniform2f(d,e.width,e.height),r.uniform1f(f,n.time),r.uniform1f(p,n.pointerX),r.uniform1f(m,n.excite),r.uniform1f(h,n.damp),r.uniform1f(g,n.dark),r.drawArrays(r.TRIANGLES,0,3)};return v(),{render:v,resize:_,dispose:()=>{r.deleteTexture(c),r.deleteBuffer(o),r.deleteProgram(a)}}}function i(e,t,n){let r=(t,n)=>{let r=e.createShader(t);return e.shaderSource(r,n),e.compileShader(r),e.getShaderParameter(r,e.COMPILE_STATUS)?r:(console.warn(e.getShaderInfoLog(r)),e.deleteShader(r),null)},i=r(e.VERTEX_SHADER,t),a=r(e.FRAGMENT_SHADER,n);if(!i||!a)return null;let o=e.createProgram();return e.attachShader(o,i),e.attachShader(o,a),e.linkProgram(o),e.getProgramParameter(o,e.LINK_STATUS)?o:(console.warn(e.getProgramInfoLog(o)),null)}async function a(e,t,n){let r=navigator.gpu,i=await r.requestAdapter();if(!i)return null;let a=await i.requestDevice(),o=e.getContext(`webgpu`);if(!o)return null;let s=r.getPreferredCanvasFormat();o.configure({device:a,format:s,alphaMode:`premultiplied`});let c=a.createShaderModule({code:`
      struct U { res: vec2f, time: f32, excite: f32, pointer: vec2f, damp: f32, dark: f32 };
      @group(0) @binding(0) var<uniform> u: U;
      @group(0) @binding(1) var samp: sampler;
      @group(0) @binding(2) var tex: texture_2d<f32>;

      
  fn spec3(t0: f32) -> vec3f {
    let t = clamp(t0, 0.0, 1.0);
    let c0 = vec3f(1.000,0.231,0.188); let c1 = vec3f(1.000,0.584,0.000); let c2 = vec3f(1.000,0.800,0.000);
    let c3 = vec3f(0.204,0.780,0.349); let c4 = vec3f(0.196,0.678,0.902); let c5 = vec3f(0.000,0.478,1.000); let c6 = vec3f(0.686,0.322,0.871);
    let x = t*6.0;
    if (x < 1.0) { return mix(c0,c1,x); }
    else if (x < 2.0) { return mix(c1,c2,x-1.0); }
    else if (x < 3.0) { return mix(c2,c3,x-2.0); }
    else if (x < 4.0) { return mix(c3,c4,x-3.0); }
    else if (x < 5.0) { return mix(c4,c5,x-4.0); }
    return mix(c5,c6,x-5.0);
  }

      @vertex fn vmain(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
        var p = array<vec2f,3>(vec2f(-1.0,-1.0), vec2f(3.0,-1.0), vec2f(-1.0,3.0));
        return vec4f(p[vi], 0.0, 1.0);
      }

      @fragment fn fmain(@builtin(position) fc: vec4f) -> @location(0) vec4f {
        let uv = vec2f(fc.x / u.res.x, fc.y / u.res.y);
        let x = uv.x;
        let pd = x - u.pointer.x;
        let bump = exp(-pd*pd/0.02) * u.excite;
        let env = pow(sin(3.14159265*clamp(x,0.0,1.0)), 1.3);
        let idle = 0.85 + 0.15*sin(u.time*0.7);
        var spec = 0.0; var col = vec3f(0.0); var disp = 0.0;
        var best = 0.0; var bestCol = vec3f(0.0);
        for (var i=0; i<5; i=i+1) {
          let fi = f32(i);
          let freq = 1.4+fi*0.42; let speed = 1.1+fi*0.22;
          let amp = (0.30-fi*0.035);
          let phase = u.time*speed+fi*0.9;
          let a = amp*env*u.damp*(idle+bump*1.6);
          let cy = 0.5+sin(6.2831853*freq*x+phase)*a;
          disp = disp + (cy-0.5);
          let d = uv.y-cy;
          let thick = 0.012+fi*0.002;
          let core = 1.0 - smoothstep(0.0, thick, abs(d));
          let glow = exp(-(d*d)/(0.010+0.006*fi));
          let hue = fract(x+fi/5.0+u.time*0.05);
          let rc = spec3(hue);
          let inten = core+glow*0.5;
          col = col + rc*inten; spec = spec + inten;
          let band = 1.0 - smoothstep(0.0, thick*1.6, abs(d));
          if (band > best) { best = band; bestCol = rc; }
        }
        let refr = disp*0.010;
        let m = textureSample(tex, samp, vec2f(uv.x+refr, uv.y)).a;
        // One design, two exposures; the GLSL twin explains it.
        let baseD = vec3f(0.42,0.43,0.47);
        let baseL = vec3f(0.155,0.150,0.140);
        let insideD = clamp(baseD + col*1.15, vec3f(0.0), vec3f(1.4));
        let insideL = mix(baseL, bestCol, best*0.95);
        let inside = mix(insideL, insideD, u.dark);
        let vign = smoothstep(0.0,0.10,x)*smoothstep(0.0,0.10,1.0-x)
                 *smoothstep(0.0,0.24,uv.y)*smoothstep(0.0,0.24,1.0-uv.y);
        let ambient = clamp(spec*0.42,0.0,1.0)*u.damp*mix(0.30,1.0,u.dark)*vign;
        let insideA = m;
        let outsideA = ambient*(1.0-m);
        let outA = insideA + outsideA*(1.0-insideA);
        let outC = (inside*insideA + col*outsideA*(1.0-insideA))/max(outA,0.001);
        return vec4f(outC*outA, outA);
      }
    `}),l=a.createBuffer({size:32,usage:GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST}),u=a.createSampler({magFilter:`linear`,minFilter:`linear`}),d=null,f=()=>{d&&d.destroy?.(),d=a.createTexture({size:[t.width,t.height],format:`rgba8unorm`,usage:GPUTextureUsage.TEXTURE_BINDING|GPUTextureUsage.COPY_DST|GPUTextureUsage.RENDER_ATTACHMENT}),a.queue.copyExternalImageToTexture({source:t},{texture:d},[t.width,t.height])};f();let p=a.createRenderPipeline({layout:`auto`,vertex:{module:c,entryPoint:`vmain`},fragment:{module:c,entryPoint:`fmain`,targets:[{format:s,blend:{color:{srcFactor:`one`,dstFactor:`one-minus-src-alpha`},alpha:{srcFactor:`one`,dstFactor:`one-minus-src-alpha`}}}]},primitive:{topology:`triangle-list`}}),m,h=()=>{m=a.createBindGroup({layout:p.getBindGroupLayout(0),entries:[{binding:0,resource:{buffer:l}},{binding:1,resource:u},{binding:2,resource:d.createView()}]})};h();let g=new ArrayBuffer(32),_=new Float32Array(g),v=()=>{_[0]=e.width,_[1]=e.height,_[2]=n.time,_[3]=n.excite,_[4]=n.pointerX,_[5]=0,_[6]=n.damp,_[7]=n.dark,a.queue.writeBuffer(l,0,g)},y=()=>{v();let e=a.createCommandEncoder(),t=e.beginRenderPass({colorAttachments:[{view:o.getCurrentTexture().createView(),clearValue:{r:0,g:0,b:0,a:0},loadOp:`clear`,storeOp:`store`}]});t.setPipeline(p),t.setBindGroup(0,m),t.draw(3),t.end(),a.queue.submit([e.finish()])};return y(),{render:y,resize:()=>{f(),h()},dispose:()=>{try{d?.destroy?.(),l.destroy?.(),a.destroy?.()}catch{}}}}