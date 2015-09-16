package zone;
use v5.14;
use Moo;

use Modern::Perl;

# TODO all this file is to redesign

use getiface ':all';
use copycat ':all';
use fileutil ':all';
use configuration ':all';
use remotecmd ':all';

use zonefile;

# primary dns interface 
has dnsi => ( is => 'rw', builder => '_void_arr');

# dns interface for secondary name servers
has dnsisec => ( is => 'rw', builder => '_void');

has [ qw/domain data/ ] => qw/is ro required 1/;

sub _void { my $x = ''; \$x; }
sub _void_arr { [] }

sub _get_ztpl_dir  {my $s = shift; "$$s{dnsi}{mycfg}{zonedir}" }
sub _get_ztpl_file {
    my $s = shift;

    # for each TLD
    for(@{$$s{data}{tld}}) {
        # if our domain is part of this TLD, get the right template
        if($$s{domain} =~ $_) {
            return $s->_get_ztpl_dir() . '/' . $_ . '.tpl';
        }
    }

    die "There is no template for $$s{domain}";
}

sub _get_ztmp_file {my $s = shift; "$$s{data}{tmpdir}/$$s{domain}" }
sub _get_tmpdir_domain {my $s = shift; "$$s{data}{tmpdir}/$$s{domain}" }

sub _get_remote_zf { 
    my $self = shift; 
    "$$self{dnsi}{mycfg}{zonedir}/$$self{domain}"
}

sub _is_same_record {
    my ($a, $b) = @_;

    #debug({ a => $a });
    #debug({ b => $b });

    #$a->{priority} eq $b->{priority} &&
    (   $a->{name} eq $b->{name} && 
        $a->{host} eq $b->{host} &&
        $a->{ttl} ==  $b->{ttl} );
}

# returns the lists of domains of a certain type
sub _get_records {
    my ($zone, $entry) = @_;

    for( lc $entry->{type} ) {
        if      ($_ eq 'a')      { return $zone->a;     }
        elsif   ($_ eq 'aaaa')   { return $zone->aaaa;  }
        elsif   ($_ eq 'cname')  { return $zone->cname; }
        elsif   ($_ eq 'ns')     { return $zone->ns;    }
        elsif   ($_ eq 'mx')     { return $zone->mx;    }
        elsif   ($_ eq 'ptr')    { return $zone->ptr;   }
    }

    die 'Impossible to get the entry type.';
}

sub get_dns_server_interfaces {
    my $self = shift;
    my $primary = $$self{data}{primarydnsserver};
    my $s = $$self{data}{secondarydnsserver};

    my $prim = getiface($$primary{app}, { mycfg => $primary, data => $self });

    my $sec = [];
    for($s) {
        for(@$_)
        {
            my $x = $_;
            push @$sec, getiface($$x{app}, { mycfg => $x, data => $self });
        }
    }

    ($prim, $sec);
}

sub BUILD {
    my $self = shift;
    ($$self{dnsi}, $$self{dnsisec}) = $self->get_dns_server_interfaces();
}

sub reload_secondary_dns_servers {
    my $self = shift;
    my $sec = $$self{data}{dnsisec};
    for(@$sec) {
        $_->reload_sec();
    }
}

sub delete_entry {
    my ($self, $entryToDelete) = @_;

    my $zone = $self->get();

    my $records = _get_records $zone, $entryToDelete;

    if( defined $records ) {
        foreach my $i ( 0 .. scalar @{$records}-1 ) {
            if(_is_same_record($records->[$i], $entryToDelete)) {
                delete $records->[$i];
            }
        }

        # TODO verify if it's OK
        $$self{data}->update_domain( $zone, $$self{domain} );
    }

}

sub modify_entry {
    my ($self, $entryToModify, $newEntry) = @_;

    my $zone = $self->get();

    my $records = _get_records $zone, $entryToModify;

    if( defined $records ) {

        foreach my $i ( 0 .. scalar @{$records}-1 ) {

            if(_is_same_record($records->[$i], $entryToModify)) {

                $records->[$i]->{name} = $newEntry->{newname};
                $records->[$i]->{host} = $newEntry->{newhost};
                $records->[$i]->{ttl}  = $newEntry->{newttl};
                $records->[$i]->{type}  = $newEntry->{newtype};

                if( defined $newEntry->{newpriority} ) {
                    $records->[$i]->{priority} = $newEntry->{newpriority};
                }
            }
        }

        # TODO verify if it's OK
        $$self{data}->update_domain( $zone, $$self{domain} );
    }

}

sub get {
    my $self = shift;
    my $file = $self->_get_remote_zf();
    my $dest = $self->_get_tmpdir_domain();

    copycat ($file, $dest);

    zonefile->new(domain => $$self{domain}, zonefile => $dest);
}

=pod
    copie du template pour créer une nouvelle zone
    update du serial
    ajout de la zone via dnsapp (rndc, knot…)
    retourne la zone + le nom de la zone
=cut

sub addzone {
    my ($self) = @_;

    my $tpl = $self->_get_ztpl_file();
    my $tmpfile = $self->_get_ztmp_file();

    copycat ($tpl, $tmpfile); # get the template

    # get the file path
    my $f = URI->new($tmpfile);

    # sed CHANGEMEORIGIN by the real origin
    mod_orig_template ($f->path, $$self{domain});

    my $zonefile = zonefile->new(zonefile => $f->path
        , domain => $$self{domain});
    $zonefile->new_serial(); # update the serial number

    # write the new zone tmpfile to disk 
    write_file $f->path, $zonefile->output();

    my $file = $self->_get_remote_zf();
    copycat ($tmpfile, $file); # put the final zone on the server
    unlink($f->path); # del the temporary file

    # add new zone on the primary ns
    $self->dnsi->addzone($$self{domain});

    # add new zone on secondary ns
    $self->reload_secondary_dns_servers();
}

=pod
    màj du serial
    push reload de la conf
=cut

sub update {
    my ($self, $zonefile) = @_;

    # update the serial number
    $zonefile->new_serial();

    my $tmpfile = $self->_get_ztmp_file();

    # write the new zone tmpfile to disk 
    write_file $tmpfile, $zonefile->output();

    my $file = $self->_get_remote_zf();
    copycat ($tmpfile, $file); # put the final zone on the server
    unlink($tmpfile); # del the temporary file

    $self->dnsi->reload($$self{domain});
}

=pod
    udpate via the raw content of the zonefile
=cut

sub update_raw {
    my ($self, $zonetext) = @_;

    my $zonefile;
    my $file = $self->_get_tmpdir_domain();

    # write the updated zone file to disk 
    write_file $file, $zonetext;

    eval { $zonefile = zonefile->new(zonefile => $file
            , domain => $$self{domain}); };

    if( $@ ) {
        unlink($file);
        die "zone update_raw : zonefile->new error";
    }

    unlink($file);

    $self->update($zonefile);
}

# sera utile plus tard, pour l'interface
sub new_tmp {
    my ($self) = @_;

    my $tpl = $self->_get_ztpl_file();
    my $file = $self->_get_tmpdir_domain();

    copycat ($tpl, $file);

    # get the file path
    my $f = URI->new($file);

    # sed CHANGEMEORIGIN by the real origin
    mod_orig_template ($f->path, $$self{domain});

    my $zonefile = zonefile->new(zonefile => $f->path, domain => $$self{domain});
    $zonefile->new_serial();

    unlink($f->path);

    return $zonefile;
}

# change the origin in a zone file template
sub mod_orig_template {
    my ($file, $domain) = @_;
    #my $cmd = qq[sed -i "s/CHANGEMEORIGIN/$domain/" $file 2>/dev/null 1>/dev/null];
    say "s/CHANGEMEORIGIN/$domain/ on $file";
    qx[sed -i "s/CHANGEMEORIGIN/$domain/" $file];
}

sub del {
    my ($self) = @_;
    $self->dnsi->delzone($$self{domain});
    $self->dnsi->reconfig();

    $self->reload_secondary_dns_servers();

    my $file = get_zonedir_from_cfg($$self{dnsi}{mycfg});
    $file .= "/$$self{domain}";

    my $host = get_host_from_cfg($$self{dnsi}{mycfg});
    my $user = get_user_from_cfg($$self{dnsi}{mycfg});
    my $port = get_port_from_cfg($$self{dnsi}{mycfg});
    my $cmd = "rm $file";

    remotecmd $user, $host, $port, $cmd;
}

1;