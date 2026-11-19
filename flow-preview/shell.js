'use strict';
const panel = document.getElementById('window');
const opener = document.getElementById('show');
const close = document.getElementById('close');
close.addEventListener('click', () => { panel.hidden = true; opener.focus(); });
opener.addEventListener('click', () => { panel.hidden = false; close.focus(); });
function updateClock() {
  const date = new Date();
  document.getElementById('clock').textContent = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' }).format(date);
}
updateClock();
setInterval(updateClock, 60000);
