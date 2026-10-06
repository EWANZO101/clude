'use strict';
/* OPS Secure CCTV live (client/cctvlive.lua): grabs the game frame through WebGL (FiveM swaps the game view into a texture
   flagged like screenshot-basic's) and sends a small JPEG back to Lua, which forwards it to the server → OPS Hub. */
(() => {
  const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'opslabs-towers';
  let gl = null, canvas = null;
  function init() {
    canvas = document.createElement('canvas');
    canvas.width = 640; canvas.height = 360;
    gl = canvas.getContext('webgl', { antialias: false, alpha: false, depth: false, preserveDrawingBuffer: true });
    if (!gl) return false;
    const sh = (t, src) => { const s = gl.createShader(t); gl.shaderSource(s, src); gl.compileShader(s); return s; };
    const prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, 'attribute vec2 p; varying vec2 v; void main(){ v = vec2(p.x*0.5+0.5, p.y*0.5+0.5); gl_Position = vec4(p,0.0,1.0); }'));
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
    const tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, new Uint8Array(3));
    // the game view: the same texture flags screenshot-basic and the phone camera use
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    return true;
  }
  function grab(w, h, q) {
    if (!gl && !init()) return null;
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    gl.viewport(0, 0, w, h);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    return canvas.toDataURL('image/jpeg', q).replace(/^data:image\/jpeg;base64,/, '');
  }
  window.addEventListener('message', (e) => {
    const m = e.data;
    if (!m || m.action !== 'cctvCapture') return;
    let jpg = null;
    try { jpg = grab(m.w || 640, m.h || 360, m.q || 0.6); } catch (err) { jpg = null; }
    fetch(`https://${RES}/cctvFrame`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ cam: m.cam, jpg, seq: m.seq }) }).catch(() => {});
  });
})();
