package Lltag::CDDB ;

use strict ;

use Lltag::Misc ;

use I18N::Langinfo qw(langinfo CODESET) ;

# return values that are passed to lltag
use constant CDDB_SUCCESS => 0 ;
use constant CDDB_ABORT => -1 ;

# local return values
use constant CDDB_ABORT_TO_KEYWORDS => -10 ;
use constant CDDB_ABORT_TO_CDIDS => -11 ;

# keep track of where we were during the previous CDDB access
my $previous_cdids = undef ;
my $previous_cd = undef ;
my $previous_track = undef ;

# confirmation behavior
my $current_cddb_yes_opt = undef ;

# HTTP browser
my $browser ;

#########################################
# init

my $cddb_supported = 1 ;

my $cddb_track_usage_forced ;
my $cddb_cd_usage_forced ;
my $cddb_keywords_usage_forced ;

sub init_cddb {
    my $self = shift ;

    if (not eval { require LWP ; } ) {
	print "LWP (libwww-perl module) does not seem to be available, disabling CDDB.\n"
	    if $self->{verbose_opt} ;
	$cddb_supported = 0 ;
	return ;
    }

    # default confirmation behavior
    $current_cddb_yes_opt = $self->{yes_opt} ;

    # HTTP browser
    $browser = LWP::UserAgent->new;
    # use HTTP_PROXY environment variable
    $browser->env_proxy ;

    # need to show menu usage once ?
    $cddb_track_usage_forced = $self->{menu_usage_once_opt} ;
    $cddb_cd_usage_forced = $self->{menu_usage_once_opt} ;
    $cddb_keywords_usage_forced = $self->{menu_usage_once_opt} ;
}

#########################################
# freedb.org specific code
# NOT USED ANYMORE since Magix acquired freedb.org
# and closed the online search module for now
#########################################

sub freedborg_cddb_response {
    my $self = shift ;
    my $path = shift ;

    print "      Sending CDDB request...\n" ;
    print "        '$path'\n" if $self->{verbose_opt} ;
    my $response = $browser->get(
	"http://"
	. $self->{cddb_server_name}
	. ($self->{cddb_server_port} != 80 ? $self->{cddb_server_port} : "")
	. $path
	. "\n"
	) ;

    if (!$response->is_success) {
	Lltag::Misc::print_error ("  ",
		"HTTP request to CDDB server ("
		. $self->{cddb_server_name} .":". $self->{cddb_server_port}
		. ") failed.") ;
	return undef ;
    }
    if ($response->content_type ne 'text/html') {
	Lltag::Misc::print_error ("  ",
		"Weird CDDB response (type ".$response->content_type.") from server "
		. $self->{cddb_server_name} .":". $self->{cddb_server_port}
		. ".") ;
	return undef ;
    }
    # TODO: grep for something to be sure it worked

    return $response->content ;
}

sub freedborg_cddb_query_cd_by_keywords {
    my $self = shift ;
    my $keywords = shift ;

    # extract fields and cat from the keywords
    my @fields = () ;
    my @cats = () ;
    my @keywords_list = () ;
    foreach my $word (split / +/, $keywords) {
	if ($word =~ m/^fields=(.+)$/) {
	    push @fields, (split /\++/, $1) ;
	} elsif ($word =~ m/^cats=(.+)$/) {
	    push @cats, (split /\++/, $1) ;
	} else {
	    push @keywords_list, $word ;
	}
    }
    # assemble remaining keywords with "+"
    $keywords = join "+", @keywords_list ;

    # by default, search in all cats, within artist and title only
    @cats = ( "all" ) unless @cats ;
    @fields = ( "artist", "title" ) unless @fields ;

    my $query_fields = (grep { $_ eq "all" } @fields) ? "allfields=YES" : "allfields=NO".(join ("", map { "&fields=$_" } @fields)) ;
    my $query_cats = (grep { $_ eq "all" } @cats) ? "allcats=YES" : "allcats=NO".(join ("", map { "&cats=$_" } @cats)) ;

    my $response = freedborg_cddb_response $self, "/freedb_search.php?words=${keywords}&${query_fields}&${query_cats}&grouping=none&x=0&y=0" ;
    return (CDDB_ABORT, undef) unless defined $response ;

    my @cdids = () ;
    my $samename = undef ;
    my $same = 0 ;

    foreach my $line (split /\n/, $response) {
	next if $line !~ /<a href=\"/ ;
	if ($line =~ m/<tr>/) {
	    $same = 0 ;
	    $samename = undef ;
	} else {
	    $same = 1;
	}
	my @links = split (/<a href=\"/, $line) ;
	shift @links ;
	while (my $link = shift @links) {
	    if ($link =~ m@http://.*/freedb_search_fmt\.php\?cat=([a-z]+)\&id=([0-9a-f]+)\">(.*)</a>@) {
		my %cdid = ( CAT => $1, ID => $2, NAME => $same ? $samename : $3 ) ;
		push @cdids, \%cdid ;
		$samename = $cdid{NAME} unless $same ;
		$same = 1;
	    }
	}
    }

    return (CDDB_SUCCESS, \@cdids) ;
}

sub freedborg_cddb_query_tracks_by_id {
    my $self = shift ;
    my $cat = shift ;
    my $id = shift ;
    my $name = shift ;

    my $response = freedborg_cddb_response $self, "/freedb_search_fmt.php?cat=${cat}&id=${id}" ;
    return (CDDB_ABORT, undef) unless defined $response ;

    my $cd ;
    $cd->{CAT} = $cat ;
    $cd->{ID} = $id ;

    foreach my $line (split /\n/, $response) {
	if ($line =~ m/tracks: (\d+)/i) {
	    $cd->{TRACKS} = $1 ;
	} elsif ($line =~ m/total time: ([\d:]+)/i) {
	    $cd->{"TOTAL TIME"} = $1 ;
	} elsif ($line =~ m/genre: (\w+)/i) {
	    $cd->{GENRE} = $1 ;
	} elsif ($line =~ m/id3g: (\d+)/i) {
	    $cd->{ID3G} = $1 ;
	} elsif ($line =~ m/year: (\d+)/i) {
	    $cd->{DATE} = $1 ;
	} elsif ($line =~ m@ *(\d+)\.</td><td valign=top> *(-?[\d:]+)</td><td><b>(.*)</b>@) {
	    # '-?' because there are some buggy entries...
	    my %track = ( TITLE => $3, TIME => $2 ) ;
	    $cd->{$1} = \%track ;
	} elsif ($line =~ m@<h2>(.+ / .+)</h2>@) {
	    if (defined $name) {
		if ($name ne $1) {
		    Lltag::Misc::print_warning ("      ", "Found CD name '$1' instead of '$name', this entry might be corrupted") ;
		}
	    } else {
		$name = $1 ;
	    }
	}
    }

    return (CDDB_SUCCESS, undef)
	unless defined $name ;

    # FIXME: are we sure no artist or album may contain " / " ?
    $name =~ m@^(.+) / (.+)$@ ;
    $cd->{ARTIST} = $1 ;
    $cd->{ALBUM} = $2 ;

    # FIXME: check number and indexes of tracks ?

    return (CDDB_SUCCESS, $cd) ;
}

sub freedborg_cddb_query_cd_by_keywords_usage {
    my $indent = shift ;
    print $indent."<space-separated keywords> => CDDB query for CD matching the keywords\n" ;
    print $indent."  Search in all CD categories within fields 'artist' and 'title' by default\n" ;
    print $indent."    cats=foo+bar   => Search in CD categories 'foo' and 'bar' only\n" ;
    print $indent."    fields=all     => Search keywords in all fields\n" ;
    print $indent."    fields=foo+bar => Search keywords in fields 'foo' and 'bar'\n" ;
    print $indent."<category>/<hexadecinal id> => CDDB query for CD matching category and id\n" ;
}

my $freedborg_cddb_backend = {
    cddb_query_cd_by_keywords => \&freedborg_cddb_query_cd_by_keywords,
    cddb_query_tracks_by_id => \&freedborg_cddb_query_tracks_by_id,
    cddb_query_cd_by_keywords_usage => \&freedborg_cddb_query_cd_by_keywords_usage,
} ;

#########################################
# tracktype.org specific code
# USED since november 2006
#########################################

sub tracktypeorg_cddb_response {
    my $self = shift ;
    my $path = shift ;
    my $postdata = shift ;

    my $response ;
    print "      Sending CDDB request...\n" ;
    if (defined $postdata) {
	print "        'POST $path'\n" if $self->{verbose_opt} ;
	$response = $browser->post(
				   "http://"
				   . $self->{cddb_server_name}
				   . ($self->{cddb_server_port} != 80 ? $self->{cddb_server_port} : "")
				   . $path,
				   $postdata
				   ) ;
    } else {
	print "        'GET $path'\n" if $self->{verbose_opt} ;
	$response = $browser->get(
				  "http://"
				  . $self->{cddb_server_name}
				  . ($self->{cddb_server_port} != 80 ? $self->{cddb_server_port} : "")
				  . $path
				  ) ;
    }

    if (!$response->is_success) {
	Lltag::Misc::print_error ("  ",
		"HTTP request to CDDB server ("
		. $self->{cddb_server_name} .":". $self->{cddb_server_port}
		. ") failed.") ;
	return undef ;
    }
    if ($response->content_type ne 'text/plain') {
	Lltag::Misc::print_error ("  ",
		"Weird CDDB response (type ".$response->content_type.") from server "
		. $self->{cddb_server_name} .":". $self->{cddb_server_port}
		. ".") ;
	return undef ;
    }

    my $content = $response->content ;

    # deal with windows line-break
    $content =~ s/\r\n/\n/g ;

    # convert from utf8 if not using a utf8 locale
    utf8::decode($content)
	unless $self->{utf8} ;

    return $content ;
}

sub tracktypeorg_cddb_query_cd_by_keywords {
    my $self = shift ;
    my $keywords = shift ;

    my %postdata = ( "hello" => "lltag",
		     "proto" => 4,
		     "cmd" => "cddb album $keywords",
		     ) ;
    my $response = tracktypeorg_cddb_response $self, "/~cddb/cddb.cgi", \%postdata ;
    return (CDDB_ABORT, undef) unless defined $response ;

    my @lines = (split /\n/, $response) ;
    # check status in header
    my $header = shift @lines ;
    # TODO: check status

    my @cdids = () ;
    foreach my $line (@lines) {
	if ($line =~ m@^([^ ]+) ([^ ]+) (.+ / .+)$@) {
	    my %cdid = ( CAT => $1, ID => $2, NAME => $3 ) ;
	    push @cdids, \%cdid ;
	}
    }

    return (CDDB_SUCCESS, \@cdids) ;
}

sub tracktypeorg_cddb_query_tracks_by_id {
    my $self = shift ;
    my $cat = shift ;
    my $id = shift ;
    my $name = shift ;

    my $response = tracktypeorg_cddb_response $self, "/freedb/${cat}/${id}" ;
    return (CDDB_ABORT, undef) unless defined $response ;

    # TODO: grep for something to be sure it worked

    my $cd ;
    $cd->{CAT} = $cat ;
    $cd->{ID} = $id ;
    $cd->{TRACKS} = 0 ;

    foreach my $line (split /\n/, $response) {
	next if $line =~ /^#/ ;
	if ($line =~ m/^DISCID=(.+)/) {
	    if ($id ne $1) {
		    Lltag::Misc::print_warning ("      ", "Found CD id '$1' instead of '$id', this entry might be corrupted") ;
	    }
	} elsif ($line =~ m@^DTITLE=(.*)@) {
	    if (defined $name) {
		if ($name ne $1) {
		    Lltag::Misc::print_warning ("      ", "Found CD name '$1' instead of '$name', this entry might be corrupted") ;
		}
	    } else {
		$name = $1 ;
	    }
	} elsif ($line =~ m/^DYEAR=(.*)/) {
	    $cd->{DATE} = $1 ;
	} elsif ($line =~ m/^DGENRE=(.*)/) {
	    $cd->{GENRE} = $1 ;
	} elsif ($line =~ m/^TTITLE(\d+)=(.*)/) {
	    my $num = $1 + 1;
	    if ($num != $cd->{TRACKS} + 1) {
		Lltag::Misc::print_warning ("      ", "Found CD track '$num' instead of '".($cd->{TRACKS}+1)."', this entry might be corrupted") ;
	    }
	    my %track = ( TITLE => $2 ) ;
	    $cd->{$num} = \%track ;
	    $cd->{TRACKS} = $num ;
	}
    }

    return (CDDB_SUCCESS, undef)
	unless defined $name ;

    # FIXME: are we sure no artist or album may contain " / " ?
    $name =~ m@^(.+) / (.+)$@ ;
    $cd->{ARTIST} = $1 ;
    $cd->{ALBUM} = $2 ;

    return (CDDB_SUCCESS, $cd) ;
}

sub tracktypeorg_cddb_query_cd_by_keywords_usage {
    my $indent = shift ;
    print $indent."<space-separated keywords> => CDDB query for CD matching the keywords\n" ;
    print $indent."  Search in all CD categories within fields 'artist' OR 'album'\n" ;
    print $indent."<category>/<hexadecinal id> => CDDB query for CD matching category and id\n" ;
}

my $tracktypeorg_cddb_backend = {
    cddb_query_cd_by_keywords => \&tracktypeorg_cddb_query_cd_by_keywords,
    cddb_query_tracks_by_id => \&tracktypeorg_cddb_query_tracks_by_id,
    cddb_query_cd_by_keywords_usage => \&tracktypeorg_cddb_query_cd_by_keywords_usage,
} ;

my $cddb_backend = $tracktypeorg_cddb_backend ;

######################################################
# interactive menu to browse CDDB, tracks in a CD

sub cddb_track_usage {
    Lltag::Misc::print_usage_header ("    ", "Choose Track in CDDB CD") ;
    print "      <index> => Choose a track of the current CD (current default is Track $previous_track)\n" ;
    print "      <index> a => Choose a track and do not ask for confirmation anymore\n" ;
    print "      a => Use default track and do not ask for confirmation anymore\n" ;
    print "      E => Edit current CD common tags\n" ;
    print "      V => View the list of CD matching the keywords\n" ;
    print "      c => Change the CD chosen in keywords query results list\n" ;
    print "      k => Start again CDDB query with different keywords\n" ;
    print "      q => Quit CDDB query\n" ;
    print "      h => Show this help\n" ;

    $cddb_track_usage_forced = 0 ;
}

sub print_cd {
    my $cd = shift ;
    map {
	print "    $_: $cd->{$_}\n" ;
    } grep { $_ !~ /^\d+$/ } (keys %{$cd}) ;
    my $track_format = "    Track %0".(length $cd->{TRACKS})."d: %s%s\n" ;
    for(my $i=1; $i <= $cd->{TRACKS}; $i++) {
	my $track = $cd->{$i} ;
	my $title = "<unknown title>" ;
	$title = $track->{TITLE} if exists $track->{TITLE} and defined $track->{TITLE} ;
	my $time = "" ;
	$time = " ($track->{TIME})" if exists $track->{TIME} and defined $track->{TIME} ;
	printf ($track_format, $i, $title, $time) ;
    }
}

sub get_cddb_tags_from_tracks {
    my $self = shift ;
    my $cd = shift ;
    my $tracknumber = undef ;

    # update previous_track to 1 or ++
    $previous_track = 0
	unless defined $previous_track ;
    $previous_track++ ;

    # if automatic mode and still in the CD, let's go
    if ($current_cddb_yes_opt and $previous_track <= $cd->{TRACKS}) {
	$tracknumber = $previous_track ;
	Lltag::Misc::print_notice ("    ", "Automatically choosing next CDDB track, #$tracknumber...") ;
	goto FOUND ;
    }

    # either in non-automatic or reached the end of the CD, dump the contents
    print_cd $cd ;

    # reached the end of CD, reset to the beginning
    if ($previous_track == $cd->{TRACKS} + 1) {
	$previous_track = 1;
	if ($current_cddb_yes_opt) {
	    Lltag::Misc::print_notice ("  ", "Reached the end of the CD, returning to interactive mode") ;
	    # return to previous confirmation behavior
	    $current_cddb_yes_opt = $self->{yes_opt} ;
	}
    }

    cddb_track_usage
	if $cddb_track_usage_forced ;

    while (1) {
	my $reply = Lltag::Misc::readline ("  ", "Enter track index [<index>aEVckq]".
			" (default is Track $previous_track, h for help)", "", -1) ;

	# if ctrl-d, abort cddb
	$reply = 'q' unless defined $reply ;

	$reply = $previous_track
	    if $reply eq '' ;

	return (CDDB_ABORT, undef)
	    if $reply =~ m/^q/ ;

	return (CDDB_ABORT_TO_KEYWORDS, undef)
	    if $reply =~ m/^k/ ;

	return (CDDB_ABORT_TO_CDIDS, undef)
	    if $reply =~ m/^c/ ;

	if ($reply =~ m/^E/) {
	    # move editable values into a temporary hash
	    my $values_to_edit = {} ;
	    foreach my $key (keys %{$cd}) {
		next if $key eq 'TRACKS' or $key =~ /^\d+$/ ;
		$values_to_edit->{$key} = $cd->{$key} ;
		delete $cd->{$key} ;
	    }
	    # clone them so that we can restore them if canceled
	    my $values_edited = Lltag::Tags::clone_tag_values ($values_to_edit) ;
	    # edit them
	    my $res = Lltag::Tags::edit_values ($self, $values_edited) ;
	    # replace the edited values with the originals if canceled
	    $values_edited = $values_to_edit if $res == Lltag::Tags->EDIT_CANCEL ;
	    # move them back
	    foreach my $key (keys %{$values_edited}) {
		$cd->{$key} = $values_edited->{$key} ;
	    }
	    next ;
	}

	if ($reply =~ m/^V/) {
	    print_cd $cd ;
	    next ;
	} ;

	if ($reply =~ m/^a/) {
	    $reply = $previous_track ;
	    $current_cddb_yes_opt = 1 ;
	}
	if ($reply =~ m/^(\d+) *a/) {
	    $current_cddb_yes_opt = 1 ;
	    $reply = $1 ;
	}

	if ($reply =~ m/^\d+$/ and $reply >= 1 and $reply <= $cd->{TRACKS}) {
	    $tracknumber = $reply ;
	    last ;
	}

	cddb_track_usage () ;
    }

   FOUND:
    my $track = $cd->{$tracknumber} ;
    # get the track tags
    my %values ;
    foreach my $key (keys %{$cd}) {
	next if $key eq 'TRACKS' or $key =~ /^\d+$/ ;
	$values{$key} = $cd->{$key} ;
    }
    $values{TITLE} = $track->{TITLE} if exists $track->{TITLE} ;
    $values{NUMBER} = $tracknumber ;

    # save the previous track number
    $previous_track = $tracknumber ;

    return (CDDB_SUCCESS, \%values) ;
}

##########################################################
# interactive menu to browse CDDB, CDs in a query results

sub cddb_cd_usage {
    Lltag::Misc::print_usage_header ("    ", "Choose CD in CDDB Query Results") ;
    print "      <index> => Choose a CD in the current keywords query results list\n" ;
    print "      V => View the list of CD matching the keywords\n" ;
    print "      k => Start again CDDB query with different keywords\n" ;
    print "      q => Quit CDDB query\n" ;
    print "      h => Show this help\n" ;

    $cddb_cd_usage_forced = 0 ;
}

sub print_cdids {
    my $cdids = shift ;

    my $cdid_format = "    %0".(length (scalar @{$cdids}))."d: %s (cat=%s, id=%s)\n" ;
    for(my $i=0; $i < @{$cdids}; $i++) {
	my $cdid = $cdids->[$i] ;
	printf ($cdid_format, $i+1, $cdid->{NAME}, $cdid->{CAT}, $cdid->{ID}) ;
    }
}

# returns (SUCCESS, undef) if CDDB returned an bad/empty CD
sub get_cddb_tags_from_cdid {
    my $self = shift ;
    my $cdid = shift ;

    my $cddb_query_tracks_by_id_func = $cddb_backend->{cddb_query_tracks_by_id} ;
    my ($res, $cd) = &{$cddb_query_tracks_by_id_func} ($self, $cdid->{CAT}, $cdid->{ID}, $cdid->{NAME}) ;
    return (CDDB_ABORT, undef) if $res == CDDB_ABORT ;

    if (!$cd or !$cd->{TRACKS}) {
	print "    There is no tracks in this CD.\n" ;
	return (CDDB_SUCCESS, undef) ;
    }

    $previous_cd = $cd ;
    undef $previous_track ;

    return get_cddb_tags_from_tracks $self, $cd ;
}

sub get_cddb_tags_from_cdids {
    my $self = shift ;
    my $cdids = shift ;

  AGAIN:
    print_cdids $cdids ;

    cddb_cd_usage
	if $cddb_cd_usage_forced ;

    while (1) {
	my $reply = Lltag::Misc::readline ("  ", "Enter CD index [<index>Vkq] (no default, h for help)", "", -1) ;

	# if ctrl-d, abort cddb
	$reply = 'q' unless defined $reply ;

	next if $reply eq '' ;

	return (CDDB_ABORT, undef)
	    if $reply =~ m/^q/ ;

	return (CDDB_ABORT_TO_KEYWORDS, undef)
	    if $reply =~ m/^k/ ;

	goto AGAIN
	    if $reply =~ m/^V/ ;

	if ($reply =~ m/^\d+$/ and $reply >= 1 and $reply <= @{$cdids}) {
	    # do the actual query for CD contents
	    my ($res, $values) = get_cddb_tags_from_cdid $self, $cdids->[$reply-1] ;
	    goto AGAIN if $res == CDDB_ABORT_TO_CDIDS or ($res == CDDB_SUCCESS and not defined $values) ;
	    return ($res, $values) ;
	}

	cddb_cd_usage () ;
    }
}

##########################################################
# interactive menu to browse CDDB, keywords query

sub cddb_keywords_usage {
    Lltag::Misc::print_usage_header ("    ", "CDDB Query by Keywords") ;
    my $cddb_query_cd_by_keywords_usage_func = $cddb_backend->{cddb_query_cd_by_keywords_usage} ;
    &{$cddb_query_cd_by_keywords_usage_func} ("      ") ;
    print "      q => Quit CDDB query\n" ;
    print "      h => Show this help\n" ;

    $cddb_keywords_usage_forced = 0 ;
}

sub get_cddb_tags {
    my $self = shift ;
    my ($res, $values) ;

    if (!$cddb_supported) {
	print "  Cannot use CDDB without LWP (libwww-perl module).\n" ;
	goto ABORT ;
    }

    if (defined $previous_cd) {
	bless $previous_cd ;
	print "  Going back to previous CD cat=$previous_cd->{CAT} id=$previous_cd->{ID}\n" ;
	($res, $values) = get_cddb_tags_from_tracks $self, $previous_cd ;
	if ($res == CDDB_ABORT_TO_CDIDS) {
	    bless $previous_cdids ;
	    ($res, $values) = get_cddb_tags_from_cdids $self, $previous_cdids ;
	}
	goto OUT if $res == CDDB_SUCCESS ;
	goto ABORT if $res == CDDB_ABORT ;
    }

    cddb_keywords_usage
	if $cddb_keywords_usage_forced ;

    while (1) {
	my $keywords ;
	if (defined $self->{requested_cddb_query}) {
	    $keywords = $self->{requested_cddb_query} ;
	    print "  Using command-line given keywords '$self->{requested_cddb_query}'...\n" ;
	    undef $self->{requested_cddb_query} ;
	    # FIXME: either put it in the history, or preput it next time
	} else {
	    $keywords = Lltag::Misc::readline ("  ", "Enter CDDB query [<query>q] (no default, h for help)", "", -1) ;
	    # if ctrl-d, abort cddb
	    $keywords = 'q' unless defined $keywords ;
	}

	next if $keywords eq '' ;

	# be careful to match the whole reply, not only the first char
	# since multiple chars are valid keyword queries

	goto ABORT
	    if $keywords eq 'q' ;

	if ($keywords eq 'h') {
	    cddb_keywords_usage () ;
	    next ;
	}

	# it this a category/id ?
	if ($keywords =~ m@^\s*(\w+)/([\da-f]+)\s*$@) {
	    my $cdid ;
	    $cdid->{CAT} = $1 ;
	    $cdid->{ID} = $2 ;
	    # FIXME: do not show 'c' for goto to CD list in there
	    ($res, $values) = get_cddb_tags_from_cdid $self, $cdid ;
	    goto OUT if $res == CDDB_SUCCESS and defined $values ;
	    goto ABORT if $res == CDDB_ABORT ;
	    next ;
	}

	# do the actual query for CD id with keywords
	my $cdids ;
	my $cddb_query_cd_by_keywords_func = $cddb_backend->{cddb_query_cd_by_keywords} ;
	($res, $cdids) = &{$cddb_query_cd_by_keywords_func} ($self, $keywords) ;
	goto ABORT if $res == CDDB_ABORT ;

	if (!@{$cdids}) {
	    print "    No CD found.\n" ;
	    next ;
	}

	$previous_cdids = $cdids ;
	$previous_cd = undef ;

	($res, $values) = get_cddb_tags_from_cdids $self, $cdids ;
	next if $res == CDDB_ABORT_TO_KEYWORDS ;
	goto OUT ;
    }

 OUT:
    goto ABORT if $res == CDDB_ABORT ;
    return ($res, $values) ;

 ABORT:
    $previous_cdids = undef ;
    $previous_cd = undef ;
    $previous_track = undef ;
    return (CDDB_ABORT, undef);
}

1 ;
