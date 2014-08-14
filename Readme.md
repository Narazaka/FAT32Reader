FAT32Reader(仮称)
=======================================

助教の人のUSBフラッシュメモリがおかしなこと(ルートフォルダ傘下のフォルダがあらぬアドレスをさしてて下位フォルダ内容があぼーん)になったんで作った。

高速実装したので仕様漏れ等ある。実際Windowsで読み出せるファイルが読み出せなかったりした。

依存
------------------

ddをつかいます。

Windowsの場合は http://www.chrysocome.net/dd を使ってください。


SYNOPSIS
------------------

    my $fr = FAT32Reader->new(
    	dd => 'dd.exe', # default = 'dd'
    	first_offset => 0, # default = 0 /dev/sdbとかから読み出す必要がある場合、PBR開始セクタ位置。fdiskとか、Windowsなら拙作「MBR/EPBR上パーティション表示スクリプト」とかで同定して書き込む。
    	if => '/dev/sdb1', # dd if=...
    	null => '/dev/null', # dd 2> ... Windowsなら'NUL'
    	sector_size => 512,
    );
    
    $fr->prepare_bpb; # BPBを読み出す。値は$fr->{bpb}にハッシュではいる。
    
    for my $name (keys %{$fr->{bpb}}){
    	print "$name = $fr->{bpb}{$name}\n";
    }
    
    $fr->prepare_fat; # FATを読み出す。
    
    print 'FAT ', $fr->is_fats_same ? 'OK' : 'NG', "\n"; # 複数記録されたFATが全部同じならOK。そうで無いならFATのどれかに破損がありそう。
    
    my $root = $fr->get_root_directory; # ルートディレクトリをさすFAT32Reader::Itemを返す。
    
    my @files = $root->list_directory_items; # FAT32Reader::Itemの配列。
    
    for my $file (@files){
    	print $file->sprintf_file_info; # lsの1行
    	if($file->{attr}{ATTR_DIRECTORY}){
    		my @sub_files = $file->list_directory_items;
    		...
    	}else{
    		if($file->{size} > 1024 ** 2){
    			$file->read_file_through($file->sprintf_name); # fileの名前に内容をddで書いてもらう。でかくて読み込みするとメモリ逝く場合とかに。
    		}else{
    			my $contents = $file->read_file; # 内容を取得。
    		}
    	}
    }
    
    my $file = $fr->get_data_item('/path/to/item'); # ルートからのパスでファイルかフォルダを指定しFAT32Reader::Itemを取得。
    
    my @files2 = $fr->list_data_items(1234); # 開始クラスタ番号からのディレクトリ内容取得。
    
    my $data = $fr->read_data_cluster(1234, 2); # 開始クラスタ番号からクラスタサイズ(第二引数 オプション)分データを取得。
    
    my $data2 = $fr->read_data_from_cluster(1234, 2 * 1024 ** 2); # 開始クラスタ番号から(FATに従い)続くひとまとまりのデータを取得。第二引数はオプションでバイトサイズを与えるとtruncateする。
    
    $fr->read_data_from_cluster_through('/path/to/store', 1234, 2 * 1024 ** 2); # read_data_from_clusterのdd of=でのリダイレクト版。第一引数は置く場所。でかくて読み込みするとメモリ逝く場合とかに。
    
    my ($fat2, $type) = $fr->fat(2); # クラスタ番号位置のFAT。$type -> empty, reserved, use to(データ継続。FATは次のクラスタ番号), use end(データエンド), broken
    
    my $dump = $fr->dd(count => 1, bs => 512, skip => 10); # 素のdd
    
    print $fr->dumper(unpack 'C*', $dump); # charの列をバイナリ表示っぽい文字列にして返す。 00f0: 11 FF 00 00 ... みたいな。
