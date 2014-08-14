use utf8;
use strict;
use warnings;
use 5.006; # not checked

package FAT32Reader;
use Encode;
use File::Spec::Functions qw/splitpath splitdir/;
our $VERSION = 0.01;

sub new{
	my $package = shift;
	my %options = (
		dd => 'dd',
		first_offset => 0,
		@_
	);
	my $self = bless \%options, ref $package || $package;
	return $self;
}

sub dd{
	my $self = shift;
	my %opt = (if => $self->{if}, @_);
	my @cmd = ($self->{dd}, map {$_.'='.$opt{$_}} keys %opt);
	my $cmd = join ' ', @cmd;
#	warn qq/$cmd/, "\n";
#	qx/$cmd 2> $null/;
#	qx/$cmd/;
	open my $fh, "$cmd 2> $self->{null} |" or die 'cannot open dump';
#	open my $fh, '-|', @cmd or die 'cannot open dump';
#	flock $fh,1;
	binmode $fh;
	local $/ = undef;
#	seek $fh,0,0;
	my $bin = <$fh>;
	close $fh;
	return $bin;
}

sub dumper{
	my $self = shift;
	my @array = @_;
	my $length = @array;
	my $line_width = 16;
	my $i = 0;
	my $dump;
	while(1){
		$dump .= sprintf '%06x', $i * $line_width;
		for my $j (0 .. $line_width - 1){
			my $p = $i * $line_width + $j;
			if($p >= $length){
				$dump .= "\n";
				return $dump;
			}
			$dump .= sprintf ' %02x', $array[$p];
		}
		$dump .= "\n";
		$i++;
	}
	return $dump;
}

sub prepare_bpb{
	my $self = shift;
	my $fat_bpb_bin = $self->dd(skip => $self->{first_offset}, bs => $self->{sector_size}, count => 1);
	my @fat_bpb = unpack 'C*', $fat_bpb_bin;
	my %bpb;
	$bpb{BS_OEMName} = pack 'C*', @fat_bpb[3 .. 10];
	$bpb{BPB_BytsPerSec} = unpack 'n', pack 'C*', $fat_bpb[12], $fat_bpb[11];
	$bpb{BPB_SecPerClus} = $fat_bpb[13];
	$bpb{BPB_RsvdSecCnt} = unpack 'n', pack 'C*', $fat_bpb[15], $fat_bpb[14];
	$bpb{BPB_NumFATs} = $fat_bpb[16];
	$bpb{BPB_TotSec32} = unpack 'N', pack 'C*', $fat_bpb[35], $fat_bpb[34], $fat_bpb[33], $fat_bpb[32];
	$bpb{BPB_FATSz32} = unpack 'N', pack 'C*', $fat_bpb[39], $fat_bpb[38], $fat_bpb[37], $fat_bpb[36];
	$bpb{BPB_RootClus} = unpack 'N', pack 'C*', $fat_bpb[47], $fat_bpb[46], $fat_bpb[45], $fat_bpb[44];
	$bpb{BS_VolLab} = pack 'C*', @fat_bpb[71 .. 81];
	$bpb{BS_FilSysType} = pack 'C*', @fat_bpb[82 .. 89];
	$self->{bpb} = \%bpb;
}

sub prepare_fat{
	my $self = shift;
	die 'do this after prepare_bpb' unless $self->{bpb};
	my %bpb = %{$self->{bpb}};
	my $offset_sector = $bpb{BPB_RsvdSecCnt};
	my $fat_bin = $self->dd(skip => $self->{first_offset} + $offset_sector, bs => $bpb{BPB_BytsPerSec}, count => $bpb{BPB_FATSz32});
	my @fat = unpack 'V*', $fat_bin;
	$self->{fat} = \@fat;
	my $fat1 = $self->fat(1);
	$self->{shutdown} = $fat1 & 0b1 ? 'safe' : 'error';
	$self->{hard} = ($fat1 >> 1) & 0b1 ? 'safe' : 'error';
}

sub is_fats_same{
	my $self = shift;
	my %bpb = %{$self->{bpb}};
	my $fat_bin;
	for my $index (0 .. $bpb{BPB_NumFATs} - 1){
		my $offset_sector = $bpb{BPB_RsvdSecCnt} + $index * $bpb{BPB_FATSz32};
		my $fat_bin_new = $self->dd(skip => $self->{first_offset} + $offset_sector, bs => $bpb{BPB_BytsPerSec}, count => $bpb{BPB_FATSz32});
		if(!defined $fat_bin or $fat_bin eq $fat_bin_new){
			$fat_bin = $fat_bin_new;
		}else{
			return;
		}
	}
	return 1;
}

#my %offset;
#my %size;
#$offset{FAT} = $bpb{BPB_RsvdSecCnt};
#$size{FAT} = $bpb{BPB_FATSz32} * $bpb{BPB_NumFATs};
#$offset{DATA} = $offset{FAT} + $size{FAT};
#$size{DATA} = $bpb{BPB_TotSec32} - $offset{DATA};
#my $fat_size = $bpb{BPB_FATSz32} * $bpb{BPB_BytsPerSec} / 4;

sub fat{
	my $self = shift;
	my $index = shift;
	die 'do this after prepare_fat' unless $self->{fat};
	my $fat = $self->{fat}[$index];
	if(wantarray){
		return $fat, $self->fat_type($fat);
	}else{
		return $fat;
	}
}

sub fat_type{
	my $self = shift;
	my $fat = shift;
	my $type;
	if($fat == 0){
		$type = 'empty';
	}elsif($fat == 1){
		$type = 'reserved';
	}elsif($fat >= 2 && $fat <= 0x0ffffff6){
		$type = 'use to';
	}elsif($fat == 0x0ffffff7){
		$type = 'broken';
	}elsif($fat >= 0x0ffffff8){
		$type = 'use end';
	}
	return $type;
}

sub read_data_cluster{
	my $self = shift;
	my $start_cluster_index = shift;
	my $cluster_size = shift || 1;
	die 'do this after prepare_bpb' unless $self->{bpb};
	my %bpb = %{$self->{bpb}};
	my $first_data_offset_sector = $bpb{BPB_RsvdSecCnt} + $bpb{BPB_FATSz32} * $bpb{BPB_NumFATs};
	my $offset_sector = $first_data_offset_sector + ($start_cluster_index - 2) * $bpb{BPB_SecPerClus};
	my $data_bin = $self->dd(skip => $self->{first_offset} + $offset_sector, bs => $bpb{BPB_BytsPerSec}, count => $bpb{BPB_SecPerClus} * $cluster_size);
	return $data_bin;
}

sub read_data_from_cluster{
	my $self = shift;
	my $index = shift;
	my $bytes_size = shift;
	my @chunks = $self->data_chunks_from_cluster($index);
	my @data;
	for my $chunk (@chunks){
		push @data, $self->read_data_cluster($chunk->{start_cluster}, $chunk->{size});
	}
	my $data = join '', @data;
	if(defined $bytes_size){
		my $content;
		open my $vh, '<', \$data;
		read $vh, $content, $bytes_size;
		close $vh;
		return $content;
	}else{
		return $data;
	}
}

sub read_data_from_cluster_through{
	my $self = shift;
	my $of = shift;
	my $index = shift;
	my $bytes_size = shift;
	die 'do this after prepare_bpb' unless $self->{bpb};
	my %bpb = %{$self->{bpb}};
	my @chunks = $self->data_chunks_from_cluster($index);
	my $first_data_offset_sector = $bpb{BPB_RsvdSecCnt} + $bpb{BPB_FATSz32} * $bpb{BPB_NumFATs};
	my $start_offset_sector = $first_data_offset_sector + ($chunks[0]->{start_cluster} - 2) * $bpb{BPB_SecPerClus};
	for my $chunk (@chunks){
		my $cluster_index = $chunk->{start_cluster};
		my $cluster_size = $chunk->{size} || 1;
		my $offset_sector = $first_data_offset_sector + ($cluster_index - 2) * $bpb{BPB_SecPerClus};
		$self->dd(of => '"'.$of.'"', seek => $offset_sector - $start_offset_sector, skip => $self->{first_offset} + $offset_sector, bs => $bpb{BPB_BytsPerSec}, count => $bpb{BPB_SecPerClus} * $cluster_size);
	}
	if(defined $bytes_size){
		open my $fh, '+<', $of;
		flock $fh, 2;
		truncate $fh, $bytes_size;
		close $fh;
	}
}

sub data_chunks_from_cluster{
	my $self = shift;
	my $index = shift;
	my @cluster_indexes;
	my $cluster_index = $index;
	while(1){
		my ($fat, $type) = $self->fat($cluster_index);
		if($type eq 'use to'){
			push @cluster_indexes, $cluster_index;
			$cluster_index = $fat;
		}elsif($type eq 'use end'){
			push @cluster_indexes, $cluster_index;
			last;
		}else{
			die 'unexpected fat type is ', $type, ' at cluster ', $cluster_index;
		}
	}
	my $start_cluster_index = $cluster_indexes[0];
	my $cluster_size = 1;
	my @chunks;
	for my $cluster_index (@cluster_indexes[1 .. $#cluster_indexes], 0){
		if($start_cluster_index + $cluster_size == $cluster_index){
			$cluster_size++;
		}else{
			push @chunks, {start_cluster => $start_cluster_index, size => $cluster_size};
			$start_cluster_index = $cluster_index;
			$cluster_size = 1;
		}
	}
	return @chunks;
}

sub bindate{
	my $self = shift;
	my $bin = unpack 'v', shift;
	my %date = (
		year => 1980 + ($bin >> 9),
		month => ($bin >> 5) & 0b1111,
		date => ($bin & 0b11111),
	);
	return sprintf "%04d-%02d-%02d", $date{year}, $date{month}, $date{date};
}

sub bintime{
	my $self = shift;
	my $bin = unpack 'v', shift;
	my %time = (
		hour => $bin >> 11,
		minute => ($bin >> 5) & 0b111111,
		second => ($bin & 0b1111) * 2,
	);
	return sprintf "%02d:%02d:%02d", $time{hour}, $time{minute}, $time{second};
}

sub data_entry_type{
	my $self = shift;
	my $bin = shift;
	my $attr = unpack 'C', substr $bin, 11, 1;
	if($attr & 0x0f){
		return 'lfn';
	}else{
		return 'sfn';
	}
}
sub data_entry_sfn_type{
	my $self = shift;
	my $flag = unpack 'C', substr shift, 0, 1;
	if(!defined $flag or $flag == 0x00){
		return 'end';
	}elsif($flag == 0xE5){
		return 'empty';
	}else{
		return 'using';
	}
}

sub is_data_entry_lfn_end{
	my $self = shift;
	0x40 & unpack 'C', substr shift, 0, 1;
}

sub is_valid_data_entry{
	my $self = shift;
	my $bin = shift;
	my $fnt = shift;
	if($fnt eq 'sfn'){
		my $type = $self->data_entry_sfn_type($bin);
		if($type eq 'empty'){
			return 1;
		}elsif($type eq 'end'){
			return 1;
		}
		my $attr = unpack 'C', substr $bin, 11, 1;
		if($attr & 0b11000000){
			return;
		}
		my $is_dir = $attr & 0x10;
		my $size = unpack 'V', substr $bin, 28, 4;
		if($is_dir and $size){
			return;
		}
		my $ntres = unpack 'C', substr $bin, 12, 1;
		unless($ntres == 0x08 or $ntres == 0x10 or $ntres == 0){
			return;
		}
		return 1;
	}else{
		my $index = unpack 'C', substr $bin, 0, 1;
		my $index_n = ($index & 0x3f);
		unless(1 <= $index_n && $index_n <= 20){
			return;
		}
		if($index & 0b10100000){
			return;
		}
		my $zero = unpack 'v', substr $bin, 26, 2;
		if($zero){
			return;
		}
		return 1;
	}
}

sub data_entry_lfn{
	my $self = shift;
	my $bin = shift;
	my $index = 0x3f & unpack 'C', substr $bin, 0, 1;
	my $chunk = (substr $bin, 1, 10) . (substr $bin, 14, 12) . (substr $bin, 28, 4);
	my $checksum = unpack 'C', substr $bin, 13, 1;
	return {index => $index, chunk => $chunk, checksum => $checksum};
}

sub data_entry_sfn{
	my $self = shift;
	my $bin = shift;
	my %file;
	$file{name} = Encode::decode 'cp932', substr $bin, 0, 11;
	my $attr = unpack 'C', substr $bin, 11, 1;
	$file{attr} = {
		ATTR_READ_ONLY => $attr & 0x01,
		ATTR_HIDDEN => $attr & 0x02,
		ATTR_SYSTEM => $attr & 0x04,
		ATTR_VOLUME_ID => $attr & 0x08,
		ATTR_DIRECTORY => $attr & 0x10,
		ATTR_ARCHIVE => $attr & 0x20,
	};
	$file{create_time} = $self->bintime(substr $bin, 14, 2);
	$file{create_date} = $self->bindate(substr $bin, 16, 2);
	$file{modify_time} = $self->bintime(substr $bin, 22, 2);
	$file{modify_date} = $self->bindate(substr $bin, 24, 2);
	$file{start_cluster} = unpack 'V', (substr $bin, 26, 2) . (substr $bin, 20, 2);
	$file{size} = unpack 'V', substr $bin, 28, 4;
	return FAT32Reader::Item->new(fs => $self, %file);
}

sub list_data_items{
	my $self = shift;
	my $index = shift;
	$index = 2 unless $index;
	my $data = $self->read_data_from_cluster($index);
	my @files;
	my @long_file_name;
	for my $i (0 .. (length $data) / 32){
		my $bin = substr $data, 32 * $i, 32;
		my $type = $self->data_entry_sfn_type($bin);
		if($type eq 'empty'){
			next;
		}elsif($type eq 'end'){
			last;
		}
		my $fnt = $self->data_entry_type($bin);
		unless($self->is_valid_data_entry($bin, $fnt)){
			if($fnt eq 'sfn'){
				die "invalid item structure\n", $self->dumper(unpack 'C*', $bin);
			}else{
				next;
			}
		}
		if($fnt eq 'sfn'){
			my $file = $self->data_entry_sfn($bin);
#			if(@long_file_name){
			if(@long_file_name and $long_file_name[0]->{checksum} == $file->lfn_checksum){
				my $long_name = Encode::decode 'utf16le', join '', map {$_->{chunk}} @long_file_name;
				$long_name =~ s/\0.*$//;
				$file->{long_name} = $long_name;
			}
			@long_file_name = ();
			push @files, $file;
		}else{
			if($self->is_data_entry_lfn_end($bin)){
				@long_file_name = ();
			}
			unshift @long_file_name, $self->data_entry_lfn($bin);
		}
	}
	return @files;
}

sub get_root_directory{
	my $self = shift;
	return FAT32Reader::Item->new(fs => $self, start_cluster => $self->{bpb}{BPB_RootClus}, name => ' ' x 11, attr => {ATTR_DIRECTORY => 1});
}

sub get_data_item{
	my $self = shift;
	my $path = shift;
	my ($drive, $directories, $target) = splitpath $path;
	my @directories = splitdir $directories;
	shift @directories unless(length $directories[0]);
	pop @directories unless(length $directories[-1]);
	push @directories, $target;
	my $item = $self->get_root_directory;
	for my $dir_name (@directories){
		my @sub_items = $item->list_directory_items;
		$item = undef;
		for my $sub_item (@sub_items){
			if($sub_item->sprintf_name eq $dir_name){
				$item = $sub_item;
				last;
			}
		}
		unless($item){
			die "element $dir_name not found: $path";
		}
	}
	return $item;
}

package FAT32Reader::Item;

sub new{
	my $package = shift;
	my %options = (
		@_
	);
	my $self = bless \%options, ref $package || $package;
	return $self;
}

sub read_file{
	my $self = shift;
	if($self->{attr}->{ATTR_DIRECTORY}){
		die 'cannot read because this is a directory: ', $self->sprintf_name;
	}
	unless($self->{size}){
		return '';
	}
	return $self->{fs}->read_data_from_cluster($self->{start_cluster}, $self->{size});
}

sub read_file_through{
	my $self = shift;
	my $of = shift;
	if($self->{attr}->{ATTR_DIRECTORY}){
		die 'cannot read because this is a directory: ', $self->sprintf_name;
	}
	unless($self->{size}){
		return '';
	}
	return $self->{fs}->read_data_from_cluster_through($of, $self->{start_cluster}, $self->{size});
}

sub list_directory_items{
	my $self = shift;
	unless($self->{attr}->{ATTR_DIRECTORY}){
		die 'cannot list because this is not a directory: ', $self->sprintf_name;
	}
	return $self->{fs}->list_data_items($self->{start_cluster});
}

sub sprintf_file_info{
	my $file = shift;
	my @info;
	push @info, $file->{attr}{ATTR_DIRECTORY} ? 'd' : '-';
	push @info, $file->{attr}{ATTR_READONLY} ? 'r-' : 'rw';
	push @info, $file->{attr}{ATTR_HIDDEN} ? 'h' : '-';
	push @info, $file->{attr}{ATTR_SYSTEM} ? 's' : '-';
	push @info, $file->{attr}{ATTR_VOLUME_ID} ? 'i' : '-';
	push @info, $file->{attr}{ATTR_ARCHIVE} ? 'a' : '-';
	push @info, ' ';
	if($file->{attr}{ATTR_DIRECTORY}){
		push @info, ' ' x 8 . '-';
	}elsif($file->{size} >= 1024 ** 3){
		push @info, sprintf '%6.1fGiB', $file->{size} / 1024 ** 3;
	}elsif($file->{size} >= 1024 ** 2){
		push @info, sprintf '%6.1fMiB', $file->{size} / 1024 ** 2;
	}elsif($file->{size} >= 1024 ** 1){
		push @info, sprintf '%6.1fKiB', $file->{size} / 1024 ** 1;
	}else{
		push @info, sprintf '    %4dB', $file->{size};
	}
	push @info, ' ';
	push @info, sprintf '%8d', $file->{start_cluster};
	push @info, ' ';
	push @info, $file->{modify_date}, 'T', $file->{modify_time};
	push @info, ' ';
	push @info, $file->sprintf_name;
	return join '', @info, "\n";
#		print 'create:', $file->{create_date}, ' ', $file->{create_time}, "\n";
#		print 'modify:', $file->{modify_date}, ' ', $file->{modify_time}, "\n";
#		print 'start cluster: ', $file->{start_cluster}, "\n";
#		print 'size: ', $file->{size}, "\n";
#		print join ' ', grep {$file->{attr}{$_}} keys %{$file->{attr}};
#		print "\n";
#		print '-' x 20, "\n";
}

sub sprintf_name{
	my $file = shift;
	if(exists $file->{long_name}){
		return $file->{long_name};
	}else{
		my $name = substr $file->{name}, 0, 8;
		my $ext = substr $file->{name}, 8, 3;
		$name =~ s/ +$//;
		$ext =~ s/ +$//;
		my $file_name = $name . (length $ext ? '.' . $ext : '');
		return lc $file_name;
	}
}

sub lfn_checksum{
	my $self = shift;
	my @name = split '', Encode::encode 'cp932', $self->{name};
	my $sum = 0;
	for my $i (0 .. 10){
		$sum = (($sum >> 1) + ($sum << 7) + ord $name[$i]) & 0xff;
	}
	return $sum;
}

1

__END__
