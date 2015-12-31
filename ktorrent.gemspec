lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)

Gem::Specification.new do |s|
  s.name        = 'k_torrent'
  s.version     = '0.1.0'
  s.date        = '2015-12-28'
  s.summary     = "KTorrent"
  s.description = "A simple implementation of the BitTorrent protocol"
  s.authors     = ["Kye Wei"]
  s.email       = 'me@kyewei.com'
  s.files       = Dir.glob("{bin,lib}/**/*") + %w(LICENSE README.md)
  s.homepage    =
    'http://rubygems.org/gems/ktorrent'
  s.license       = 'MIT'
end
