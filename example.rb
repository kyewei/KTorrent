require './k_torrent'
# Run something like this script
# Alternatively, load in interactive: 'irb -I ./lib -r k_torrent'

::KTorrent.debug_on = true
torrent = ::KTorrent::Manager.manager.load_torrent_from_file("multiple.torrent"); "Test file loaded"
torrent.start
