const scanButton = document.querySelector('#run-scan');
const scanStatus = document.querySelector('#scan-status');
const totalValue = document.querySelector('[data-total]');
const scanButtonLabel = scanButton?.lastChild;

const sampleScans = [
  { total: '142.8', xcode: '68.4 GB', docker: '31.2 GB', tooling: '24.7 GB', projects: '18.5 GB', status: 'Sample results · ready for review' },
  { total: '87.3', xcode: '41.6 GB', docker: '19.8 GB', tooling: '15.4 GB', projects: '10.5 GB', status: 'Sample results · compact workspace' },
  { total: '211.6', xcode: '96.1 GB', docker: '52.4 GB', tooling: '38.7 GB', projects: '24.4 GB', status: 'Sample results · large toolchain' },
];

let scanIndex = 0;
let scanBusy = false;

function updateScan(data) {
  totalValue.textContent = data.total;
  scanStatus.textContent = data.status;
  Object.entries(data).forEach(([key, value]) => {
    const target = document.querySelector(`[data-space="${key}"]`);
    if (target) target.textContent = value;
  });
}

scanButton?.addEventListener('click', () => {
  if (scanBusy) return;
  scanBusy = true;
  scanButton.disabled = true;
  scanStatus.textContent = 'Scanning known zones · mapping…';
  if (scanButtonLabel) scanButtonLabel.textContent = ' Scanning';
  scanButton.classList.add('is-scanning');

  window.setTimeout(() => {
    scanIndex = (scanIndex + 1) % sampleScans.length;
    updateScan(sampleScans[scanIndex]);
    if (scanButtonLabel) scanButtonLabel.textContent = ' Run a sample scan';
    scanButton.classList.remove('is-scanning');
    scanButton.disabled = false;
    scanBusy = false;
  }, 700);
});

const revealItems = document.querySelectorAll('[data-reveal]');
const revealObserver = new IntersectionObserver((entries, observer) => {
  entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    const delay = entry.target.dataset.delay;
    if (delay) entry.target.style.transitionDelay = `${delay}ms`;
    entry.target.classList.add('is-visible');
    observer.unobserve(entry.target);
  });
}, { threshold: 0.12 });

revealItems.forEach((item) => revealObserver.observe(item));

const menuToggle = document.querySelector('.menu-toggle');
const mobileNav = document.querySelector('#mobile-nav');

menuToggle?.addEventListener('click', () => {
  const isOpen = menuToggle.getAttribute('aria-expanded') === 'true';
  menuToggle.setAttribute('aria-expanded', String(!isOpen));
  menuToggle.setAttribute('aria-label', isOpen ? 'Open navigation' : 'Close navigation');
  mobileNav?.classList.toggle('is-open', !isOpen);
});

mobileNav?.querySelectorAll('a').forEach((link) => {
  link.addEventListener('click', () => {
    menuToggle?.setAttribute('aria-expanded', 'false');
    menuToggle?.setAttribute('aria-label', 'Open navigation');
    mobileNav.classList.remove('is-open');
  });
});
