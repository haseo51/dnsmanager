#!/usr/bin/perl -w
use v5.14;
use autodie;
use Modern::Perl;

use Data::Dump qw( dump );

use lib './lib/';
use configuration ':all';
use app;
use utf8;

if( @ARGV != 0 ) {
    say "usage : ./$0";
    exit 1;
}

eval {
    my $app = app->new(get_cfg());
    my $users = $app->get_all_users();
    dump($users);
};

if( $@ ) {
    say q{Une erreur est survenue. } . $@;
}
