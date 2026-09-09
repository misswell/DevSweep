const requestedCard = new URLSearchParams(window.location.search).get('card');
const allowedCards = new Set(['scan', 'coverage', 'safety']);
const card = allowedCards.has(requestedCard) ? requestedCard : 'scan';

document.body.dataset.card = card;
document.title = {
  scan: 'DevSweep · 先扫描，再决定',
  coverage: 'DevSweep · 全栈工具链，一次看清',
  safety: 'DevSweep · 清理，也要有边界',
}[card];
