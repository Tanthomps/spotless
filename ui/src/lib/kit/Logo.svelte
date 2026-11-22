<script module lang="ts">
	// Spotless's mark (site/assets/spotless.svg, the same one as the iPhone app's icon and splash):
	// a play triangle split by two arcs, in Spotify green. Drawn without its black tile in the app.
	export const MARK_D = 'M400 431.22L400 449.02A33.5 33.5 0 0 0 429.38 482.26A417.4 417.4 0 0 1 747.31 701.81A28.5 28.5 0 0 0 786.77 713.2L812.09 698.58A81.5 81.5 0 0 0 812.09 557.42L496.75 375.36A64.5 64.5 0 0 0 400 431.22ZM400 560.38L400 594.41A33.5 33.5 0 0 0 429.77 627.7A290.2 290.2 0 0 1 644.34 763.51A28.5 28.5 0 0 0 682.84 773.2L701.93 762.18A28.5 28.5 0 0 0 712.65 723.76A391.1 391.1 0 0 0 439.45 527.42A33.5 33.5 0 0 0 400 560.38ZM400 706.48L400 816.99A69 69 0 0 0 503.5 876.74L595.33 823.73A28.5 28.5 0 0 0 605.24 783.94A241.8 241.8 0 0 0 438.86 673.41A33.5 33.5 0 0 0 400 706.48Z';
	export const MARK_COLOR = '#1ED760';
	/** The mark's square in the master's 1254 box. */
	export const MARK_BOX = '345 345 564 564';
</script>

<script lang="ts">
	/** The mark at `size` px. */
	let { size = 32, class: className = '' }: { size?: number; class?: string } = $props();
</script>

<svg width={size} height={size} viewBox={MARK_BOX} aria-hidden="true" class="shrink-0 {className}">
	<path fill={MARK_COLOR} d={MARK_D} />
</svg>
