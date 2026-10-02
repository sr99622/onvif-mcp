const SIDEBAR_STORAGE_KEY = "camera-switchboard:sidebar-collapsed";
const app = document.querySelector(".app");
const list = document.querySelector("#camera-list");
const player = document.querySelector("#player");
const cameraName = document.querySelector("#camera-name");
const cameraAddress = document.querySelector("#camera-address");
const status = document.querySelector("#status");
const sidebarToggle = document.querySelector("#sidebar-toggle");

let cameras = [];
let selectedIndex = -1;

function setSidebarCollapsed(collapsed) {
  app.classList.toggle("sidebar-collapsed", collapsed);
  sidebarToggle.setAttribute("aria-expanded", String(!collapsed));
  sidebarToggle.title = collapsed ? "Show controls" : "Collapse controls";
  sidebarToggle.querySelector(".visually-hidden").textContent =
    collapsed ? "Show controls" : "Collapse controls";
  localStorage.setItem(SIDEBAR_STORAGE_KEY, JSON.stringify(collapsed));
}

function initializeSidebarToggle() {
  const collapsed = localStorage.getItem(SIDEBAR_STORAGE_KEY) === "true";
  setSidebarCollapsed(collapsed);
  sidebarToggle.addEventListener("click", () => {
    setSidebarCollapsed(!app.classList.contains("sidebar-collapsed"));
  });
}

function selectCamera(index) {
  if (!cameras.length) return;

  selectedIndex = (index + cameras.length) % cameras.length;
  const camera = cameras[selectedIndex];

  player.src = camera.media_player_url;
  cameraName.textContent = camera.hostname;
  cameraAddress.textContent = `${camera.ip_address} · ${camera.manufacturer} ${camera.model}`;
  status.textContent = `${cameras.length} cameras available`;

  document.querySelectorAll(".camera-button").forEach((button, buttonIndex) => {
    button.classList.toggle("active", buttonIndex === selectedIndex);
    button.setAttribute("aria-current", buttonIndex === selectedIndex ? "true" : "false");
  });

  localStorage.setItem("camera-switchboard:last-camera", camera.hostname);
}

async function initialize() {
  try {
    const response = await fetch("/outputs/camera_registry.json", { cache: "no-store" });
    if (!response.ok) throw new Error(`Registry request failed: ${response.status}`);

    const registry = await response.json();
    cameras = registry.cameras.filter((camera) => camera.media_player_url);

    cameras.forEach((camera, index) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "camera-button";
      button.textContent = camera.hostname;
      button.addEventListener("click", () => selectCamera(index));
      list.appendChild(button);
    });

    const savedName = localStorage.getItem("camera-switchboard:last-camera");
    const savedIndex = cameras.findIndex((camera) => camera.hostname === savedName);
    selectCamera(savedIndex >= 0 ? savedIndex : 0);
  } catch (error) {
    status.textContent = "Unable to load camera registry";
    cameraName.textContent = "Dashboard unavailable";
    cameraAddress.textContent = error.message;
  }
}

initializeSidebarToggle();
initialize();
