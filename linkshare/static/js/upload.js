(function(){
  const dropzone = document.getElementById('dropzone');
  const dzInner = document.getElementById('dzInner');
  const dzProgress = document.getElementById('dzProgress');
  const fileInput = document.getElementById('fileInput');
  const progressFill = document.getElementById('progressFill');
  const progressPct = document.getElementById('progressPct');
  const resultCard = document.getElementById('result');
  const resultUrl = document.getElementById('resultUrl');
  const copyBtn = document.getElementById('copyBtn');
  const openLink = document.getElementById('openLink');
  const expireNote = document.getElementById('expireNote');
  const errorBox = document.getElementById('errorBox');

  function showError(msg){
    errorBox.textContent = msg;
    errorBox.hidden = false;
    setTimeout(() => { errorBox.hidden = true; }, 6000);
  }

  function resetDropzone(){
    dzInner.hidden = false;
    dzProgress.hidden = true;
    progressFill.style.width = '0%';
    progressPct.textContent = '0%';
  }

  function startUpload(file){
    if (!file) return;
    resultCard.hidden = true;
    errorBox.hidden = true;
    dzInner.hidden = true;
    dzProgress.hidden = false;

    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/upload', true);

    xhr.upload.onprogress = function(e){
      if (e.lengthComputable){
        const pct = Math.round((e.loaded / e.total) * 100);
        progressFill.style.width = pct + '%';
        progressPct.textContent = pct + '%';
      }
    };

    xhr.onload = function(){
      resetDropzone();
      let data;
      try { data = JSON.parse(xhr.responseText); } catch(e){ data = null; }

      if (xhr.status >= 200 && xhr.status < 300 && data && data.url){
        resultUrl.value = data.url;
        openLink.href = data.url;
        expireNote.textContent = 'Deletes automatically in 12 hours';
        resultCard.hidden = false;
      } else {
        showError((data && data.error) || 'Upload failed. Try again.');
      }
    };

    xhr.onerror = function(){
      resetDropzone();
      showError('Network error during upload.');
    };

    const formData = new FormData();
    formData.append('file', file);
    xhr.send(formData);
  }

  dropzone.addEventListener('click', () => fileInput.click());
  fileInput.addEventListener('change', () => {
    if (fileInput.files.length) startUpload(fileInput.files[0]);
  });

  ['dragenter','dragover'].forEach(evt => {
    dropzone.addEventListener(evt, (e) => {
      e.preventDefault(); e.stopPropagation();
      dropzone.classList.add('dragover');
    });
  });
  ['dragleave','drop'].forEach(evt => {
    dropzone.addEventListener(evt, (e) => {
      e.preventDefault(); e.stopPropagation();
      dropzone.classList.remove('dragover');
    });
  });
  dropzone.addEventListener('drop', (e) => {
    const files = e.dataTransfer.files;
    if (files.length) startUpload(files[0]);
  });

  copyBtn.addEventListener('click', () => {
    resultUrl.select();
    resultUrl.setSelectionRange(0, 99999);
    navigator.clipboard.writeText(resultUrl.value).then(() => {
      copyBtn.textContent = 'Copied!';
      setTimeout(() => { copyBtn.textContent = 'Copy'; }, 1500);
    });
  });
})();
