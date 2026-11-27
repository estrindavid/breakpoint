// Helpers for hero.html. Runs only while rendering (headless Chrome); nothing here reaches the
// README.

// The brand mark, from Sources/BreakpointKit/Design/BrandMark.swift (24-unit grid): a rounded tag
// pointing right with two oval eyes set a little above centre.
const TAG = "M5 6h9.6c.5 0 1 .2 1.3.6l5.3 4.5c.5.5.5 1.3 0 1.8l-5.3 4.5c-.3.4-.8.6-1.3.6H5a3 3 0 0 1-3-3V9a3 3 0 0 1 3-3z";
const EYES = "M6.2 11.4a1.5 1.8 0 1 0 3 0a1.5 1.8 0 1 0-3 0zM10.8 11.4a1.5 1.8 0 1 0 3 0a1.5 1.8 0 1 0-3 0z";
let markCount = 0;

// The mark in the brand gradient (mint → indigo), `height` CSS pixels tall.
function markSVG(height) {
  const id = "m" + (++markCount);
  const w = height * 21.5 / 13.5;
  return `<svg width="${w}" height="${height}" viewBox="1.25 5.25 21.5 13.5" xmlns="http://www.w3.org/2000/svg">
    <defs><linearGradient id="${id}g" x1="2" y1="6" x2="21.6" y2="18" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#3DD6B0"/><stop offset="1" stop-color="#6C7CFF"/></linearGradient></defs>
    <path fill-rule="evenodd" d="${TAG}${EYES}" fill="url(#${id}g)"/></svg>`;
}

// <div class="crop" data-src="snap/…png" data-rect="x,y,w,h" data-scale="1" data-radius="28">
// rect is in the snapshot's own 2x pixels; scale 1 shows it 1:1 in the 2x capture.
function buildCrops() {
  for (const el of document.querySelectorAll(".crop[data-src]")) {
    const [x, y, w, h] = el.dataset.rect.split(",").map(Number);
    const s = Number(el.dataset.scale || 1) / 2;
    const img = new Image();
    img.src = el.dataset.src;
    el.style.width = (w * s) + "px";
    el.style.height = (h * s) + "px";
    if (el.dataset.radius) el.style.borderRadius = el.dataset.radius === "pill" ? (h * s / 2) + "px" : (Number(el.dataset.radius) * Number(el.dataset.scale || 1)) + "px";
    img.style.left = (-x * s) + "px";
    img.style.top = (-y * s) + "px";
    img.onload = () => { img.style.width = (img.naturalWidth * s) + "px"; };
    el.appendChild(img);
  }
  for (const el of document.querySelectorAll("[data-mark]")) {
    el.innerHTML = markSVG(Number(el.dataset.h));
  }
}
document.addEventListener("DOMContentLoaded", buildCrops);
