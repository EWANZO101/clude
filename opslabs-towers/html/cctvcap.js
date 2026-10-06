'use strict';
/* OPS Secure CCTV live (client/cctvlive.lua): grabs the game frame through WebGL (FiveM swaps the game view into a texture
   flagged like screenshot-basic's) and sends a small JPEG back to Lua, which forwards it to the server → OPS Hub.
   Set up exactly like the phone camera (opslabs-phone html/js/apps/camera.js), which is known to work: texture options
   before the upload, then the WRAP_T sequence FiveM watches for, and nothing on the texture after it. The view is drawn
   every frame while captures are coming in (the swapped-in texture is only live while it's being drawn), and a capture
   is taken from a frame drawn in the same task. */
(() => {
  const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'opslabs-towers';
  let gl = null, canvas = null, tex = null, uCrop = null;
  let looping = false, lastWant = 0, frames = 0;
  const queue = [];

  function init() {
    canvas = document.createElement('canvas');
    canvas.width = 640; canvas.height = 360;
    gl = canvas.getContext('webgl', { antialias: false, depth: false, stencil: false, alpha: false, desynchronized: true, failIfMajorPerformanceCaveat: false, preserveDrawingBuffer: false });
    if (!gl) return false;
    const sh = (t, src) => { const s = gl.createShader(t); gl.shaderSource(s, src); gl.compileShader(s); return s; };
    const prog = gl.createProgram();
    // uCrop = the centre of the game frame with the picture's shape (16:9), so wide / tall screens aren't stretched
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, 'attribute vec2 p; varying vec2 v; uniform vec4 uCrop; void main(){ v = uCrop.xy + vec2(p.x*0.5+0.5, p.y*0.5+0.5) * uCrop.zw; gl_Position = vec4(p,0.0,1.0); }'));
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, 'precision mediump float; varying vec2 v; uniform sampler2D t; void main(){ gl_FragColor = vec4(texture2D(t, v).rgb, 1.0); }'));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return false;
    gl.useProgram(prog);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, 'p');
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    // the game view — set up exactly like screenshot-basic (citizenfx/screenshot-basic), FiveM's own screenshot resource:
    // a 1×1 BLUE placeholder (a blue picture = FiveM never swapped the game in; black = it did but the game drew nothing),
    // then the WRAP_T sequence FiveM's NUI watches for, ending on CLAMP_TO_EDGE
    tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([0, 0, 255, 255]));
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.uniform1i(gl.getUniformLocation(prog, 't'), 0);
    uCrop = gl.getUniformLocation(prog, 'uCrop');
    return true;
  }

  function draw(w, h) {
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    gl.viewport(0, 0, w, h);
    const g = (window.innerWidth || 16) / (window.innerHeight || 9), a = w / h;   // the NUI page covers the game window
    gl.uniform4fv(uCrop, a < g ? [(1 - a / g) / 2, 0, a / g, 1] : [0, (1 - g / a) / 2, 1, g / a]);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  /** a tiny brightness check of the frame just drawn (an all-black frame means the game view isn't coming through) */
  function lit() {
    const px = new Uint8Array(4 * 16);
    try { gl.readPixels(0, Math.floor(canvas.height / 2), 16, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); } catch (e) { return true; }
    let s = 0, blue = 0;
    for (let i = 0; i < px.length; i += 4) { s += px[i] + px[i + 1]; if (px[i] < 8 && px[i + 1] < 8 && px[i + 2] > 240) blue++; }
    return s > 0 && blue < 12;          // all black or the blue placeholder: not the game yet
  }

  function send(m, jpg, blank) {
    fetch(`https://${RES}/cctvFrame`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ cam: m.cam, jpg, seq: m.seq, blank: !!blank }) }).catch(() => {});
  }

  function loop() {
    if (Date.now() - lastWant > 4000) { looping = false; return; }       // nobody's asking: stop drawing
    frames++;
    draw(canvas.width, canvas.height);
    // captures wait a couple of drawn frames so the game view has been swapped in
    if (frames > 2) {
      while (queue.length) {
        const m = queue.shift();
        let jpg = null;
        try {
          draw(m.w || 640, m.h || 360);
          if (lit()) jpg = canvas.toDataURL('image/jpeg', m.q || 0.6).replace(/^data:image\/jpeg;base64,/, '');
          else if ((m.tries || 0) >= 3) { send(m, null, true); continue; }   // the game isn't giving its picture: say so, send nothing
          else { m.tries = (m.tries || 0) + 1; queue.push(m); break; }       // not yet: try again on a later frame
        } catch (err) { jpg = null; }
        if (jpg) send(m, jpg);
      }
    }
    requestAnimationFrame(loop);
  }

  window.addEventListener('message', (e) => {
    const m = e.data;
    if (!m || m.action !== 'cctvCapture') return;
    if (!gl && !init()) return send(m, null);
    lastWant = Date.now();
    queue.push(m);
    if (queue.length > 3) queue.shift();                                // never fall behind
    if (!looping) { looping = true; frames = 0; requestAnimationFrame(loop); }
  });
})();
