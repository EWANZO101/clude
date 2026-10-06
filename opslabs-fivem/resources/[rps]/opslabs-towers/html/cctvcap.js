'use strict';
/* OPS Secure CCTV live (client/cctvlive.lua): grabs the game frame through WebGL and sends a JPEG back to Lua, which
   forwards it to the server → OPS Hub.

   The game picture reaches NUI through FiveM's "game view" texture. This copies what @citizenfx/three's CfxTexture does
   (the texture screenshot-basic renders with), step for step:
     · texture options first (texParameteri), unpack alignment 1, no flip
     · upload a 1×1 RGB pixel
     · then exactly   WRAP_T = CLAMP_TO_EDGE → MIRRORED_REPEAT → REPEAT   (texParameterf) — nothing touches it after
   and, like screenshot-basic, the canvas sits in the page and is drawn every frame from page load.
   The 1×1 placeholder is blue: a blue capture means FiveM never swapped the game picture in. */
(() => {
  const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'opslabs-towers';
  let gl = null, canvas = null, uCrop = null;
  const queue = [];

  function init() {
    canvas = document.createElement('canvas');
    canvas.width = 640; canvas.height = 360;
    canvas.style.cssText = 'position:absolute;left:-10000px;top:0;width:1px;height:1px;pointer-events:none;';
    (document.body || document.documentElement).appendChild(canvas);
    gl = canvas.getContext('webgl', { antialias: false, alpha: false, depth: true, stencil: true, premultipliedAlpha: true, preserveDrawingBuffer: false });
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

    // ---- the game view texture, as CfxTexture / WebGLTextures.uploadTexture does it
    const tex = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, new Uint8Array([0, 0, 255]));
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT);
    gl.texParameterf(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    // ----

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

  /** the frame just drawn: black, the blue placeholder, or the game */
  function lit() {
    const px = new Uint8Array(4 * 16);
    try { gl.readPixels(0, Math.floor(canvas.height / 2), 16, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); } catch (e) { return true; }
    let s = 0, blue = 0;
    for (let i = 0; i < px.length; i += 4) { s += px[i] + px[i + 1]; if (px[i] < 8 && px[i + 1] < 8 && px[i + 2] > 240) blue++; }
    return s > 0 && blue < 12;
  }

  function send(m, jpg, blank) {
    fetch(`https://${RES}/cctvFrame`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ cam: m.cam, jpg, seq: m.seq, blank: !!blank }) }).catch(() => {});
  }

  // drawn every frame from page load, like screenshot-basic; captures are taken from a frame drawn in the same task
  function loop() {
    requestAnimationFrame(loop);
    if (!gl) return;
    draw(canvas.width, canvas.height);
    while (queue.length) {
      const m = queue.shift();
      let jpg = null;
      try {
        draw(m.w || 640, m.h || 360);
        if (lit()) jpg = canvas.toDataURL('image/jpeg', m.q || 0.6).replace(/^data:image\/jpeg;base64,/, '');
        else if ((m.tries || 0) >= 3) { send(m, null, true); continue; }   // the game isn't giving its picture: say so
        else { m.tries = (m.tries || 0) + 1; queue.push(m); break; }       // not yet: try again on a later frame
      } catch (err) { jpg = null; }
      if (jpg) send(m, jpg);
    }
  }

  function start() {
    if (!init()) gl = null;
    requestAnimationFrame(loop);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();

  window.addEventListener('message', (e) => {
    const m = e.data;
    if (!m || m.action !== 'cctvCapture') return;
    if (!gl) return send(m, null, true);
    queue.push(m);
    if (queue.length > 3) queue.shift();                                // never fall behind
  });
})();
