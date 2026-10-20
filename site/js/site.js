// Screenshot strip indicators: mark the slide in view and let the dots scroll to a slide.
(function () {
	var strip = document.querySelector('.strip');
	var dots = document.querySelector('.dots');
	if (!strip || !dots || !('IntersectionObserver' in window)) return;

	var figures = Array.prototype.slice.call(strip.querySelectorAll('figure'));
	var buttons = Array.prototype.slice.call(dots.querySelectorAll('button'));
	var reduce = window.matchMedia('(prefers-reduced-motion: reduce)');

	function select(index) {
		buttons.forEach(function (button, i) {
			if (i === index) button.setAttribute('aria-current', 'true');
			else button.removeAttribute('aria-current');
		});
	}

	var observer = new IntersectionObserver(function (entries) {
		entries.forEach(function (entry) {
			if (entry.isIntersecting) select(figures.indexOf(entry.target));
		});
	}, { root: strip, threshold: 0.6 });
	figures.forEach(function (figure) { observer.observe(figure); });

	buttons.forEach(function (button, i) {
		button.addEventListener('click', function () {
			figures[i].scrollIntoView({
				behavior: reduce.matches ? 'auto' : 'smooth',
				inline: 'center',
				block: 'nearest'
			});
		});
	});

	select(0);
	dots.hidden = false;
})();
