<?php

# $menuEntries is an array of menu entries for this plugin - see
# fpp-plugin-Template/menu.inc and PLUGIN_GUIDELINES.md #9.1 (at most ONE
# entry per type: status/content/output/help). Encore Radio is a single
# config+control page, so it only ever appears under 'status'.

$menuEntries = Array(
	Array(
		'text' => 'Encore Radio',
		'type' => 'status',
		'page' => 'www/index.php',
		'wrap' => 1
	)
);

foreach ($menuEntries as $entry)
{
	if ($entry['type'] != $menu)
		continue;

	if (preg_match('/^http.?:\/\//', $entry['page']))
	{
		printf("<li><a href='%s' target='_blank'>%s</a></li>\n",
			$entry['page'], $entry['text']);
	}
	else
	{
		$nopage = '';
		if (isset($entry['wrap']) && ($entry['wrap'] == 0))
			$nopage = '&nopage=1';

		printf("<li><a href='plugin.php?plugin=%s&page=%s%s'>%s</a></li>\n",
			$plugin, $entry['page'], $nopage, $entry['text']);
	}
}
?>
