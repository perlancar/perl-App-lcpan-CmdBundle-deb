package App::lcpan::Cmd::debian_dist2deb;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any::IfLOG '$log';

require App::lcpan;

our %SPEC;

$SPEC{handle_cmd} = {
    v => 1.1,
    summary => 'Show Debian package name/version for a dist',
    description => <<'_',

This routine uses the simple rule of: converting the dist name to lowercase then
add "lib" prefix and "-perl" suffix. A small percentage of Perl distributions do
not follow this rule.

_
    args => {
        %App::lcpan::common_args,
        %App::lcpan::dists_args,
        check_exists_on_debian => {
            summary => 'Check each distribution if its Debian package exists, using Dist::Util::Debian::dist_has_deb',
            schema => 'bool*',
        },
        use_allpackages => {
            summary => 'Will be passed to Dist::Util::Debian::dist_has_deb',
            description => <<'_',

Using this option is faster if you need to check existence for many Debian
packages. See <pm:Dist::Util::Debian> documentation for more details.

_
            schema => 'bool*',
        },
        exists_on_debian => {
            summary => 'Only output debs which exist on Debian repository',
            'summary.alt.bool.not' => 'Only output debs which do not exist on Debian repository',
            schema => 'bool*',
            tags => ['category:filtering'],
        },
        exists_on_cpan => {
            summary => 'Only output debs which exist in database',
            'summary.alt.bool.not' => 'Only output debs which do not exist in database',
            schema => 'bool*',
            tags => ['category:filtering'],
        },
        needs_update => {
            summary => 'Only output debs which has smaller version than its CPAN counterpart',
            'summary.alt.bool.not' => 'Only output debs which has the same version as its CPAN counterpart',
            schema => 'bool*',
            tags => ['category:filtering'],
        },
    },
};
sub handle_cmd {
    require Dist::Util::Debian;

    my %args = @_;

    my $state = App::lcpan::_init(\%args, 'ro');
    my $dbh = $state->{dbh};

    my @rows;
    my @fields = qw(dist deb);

    for my $dist (@{ $args{dists} }) {
        my $deb = Dist::Util::Debian::dist2deb($dist);
        my $row = {dist => $dist, deb => $deb};
        push @rows, $row;
    }

    {
        push @fields, "dist_version";
        my $sth = $dbh->prepare(
            "SELECT name,version FROM dist WHERE is_latest AND name IN (".
                join(",", map { $dbh->quote($_) } @{ $args{dists} }).")");
        $sth->execute;
        my %versions;
        while (my $row = $sth->fetchrow_hashref) {
            $versions{$row->{name}} = $row->{version};
        }
        for (0..$#rows) {
            $rows[$_]{dist_version} = $versions{$rows[$_]{dist}};
        }
        if (defined $args{exists_on_cpan}) {
            @rows = grep { !(defined $_->{dist_version} xor $args{exists_on_cpan}) } @rows;
        }
    }

    if ($args{check_exists_on_debian} || defined $args{exists_on_debian} || defined $args{needs_update}) {
        push @fields, "deb_version";
        my $opts = {};
        $opts->{use_allpackages} = 1 if $args{use_allpackages} // $args{exists};

        my @res = Dist::Util::Debian::deb_ver($opts, map {$_->{deb}} @rows);
        for (0..$#rows) { $rows[$_]{deb_version} = $res[$_] }
        if (defined $args{exists_on_debian}) {
            @rows = grep { !(defined $_->{deb_version} xor $args{exists_on_debian}) } @rows;
        }
        if (defined $args{needs_update}) {
            my @frows;
            for (@rows) {
                my $v = $_->{deb_version};
                next unless defined $v;
                $v =~ s/-.+$//;
                if ($args{needs_update}) {
                    next unless version->parse($v) <  version->parse($_->{dist_version});
                } else {
                    next unless version->parse($v) == version->parse($_->{dist_version});
                }
                push @frows, $_;
            }
            @rows = @frows;
        }
    }

    [200, "OK", \@rows, {'table.fields' => \@fields}];
}

1;
# ABSTRACT:

=head1 SYNOPSIS

Convert some distribution names to Debian package names (using simple rule of
converting dist to lowercase and adding "lib" prefix and "-perl" suffix):

 % cat dists.txt
 HTTP-Tiny
 App-lcpan
 Data-Dmp
 Foo

 % lcpan debian-dist2deb < dists.txt
 +-----------+-------------------+--------------+
 | dist      | deb               | dist_version |
 +-----------+-------------------+--------------+
 | HTTP-Tiny | libhttp-tiny-perl | 0.070        |
 | App-lcpan | libapp-lcpan-perl | 1.014        |
 | Data-Dmp  | libdata-dmp-perl  | 0.22         |
 | Foo       | libfoo-perl       |              |
 +-----------+-------------------+--------------+

Like the above, but also check that Debian package exists in the Debian
repository (will show package version if exists, or undef if not exists):

 % lcpan debian-dist2deb --check-exists-on-debian < dists.txt
 +-----------+-------------------+--------------+-------------+
 | dist      | deb               | dist_version | deb_version |
 +-----------+-------------------+--------------+-------------+
 | HTTP-Tiny | libhttp-tiny-perl | 0.070        | 0.070-1     |
 | App-lcpan | libapp-lcpan-perl | 1.014        |             |
 | Data-Dmp  | libdata-dmp-perl  | 0.22         | 0.21-1      |
 | Foo       | libfoo-perl       |              |             |
 +-----------+-------------------+--------------+-------------+

Like the above, but download (and cache) allpackages.txt.gz first to speed up
checking if you need to check many Debian packages:

 % lcpan debian-dist2deb --check-exists-on-debian --use-allpackages

Only show dists where the Debian package exists on Debian repo
(C<--exists-on-debian> implicitly turns on C<--check-exists-on-debian>):

 % lcpan debian-dist2deb --exists-on-debian --use-allpackages < dists.txt
 +-----------+-------------------+--------------+-------------+
 | dist      | deb               | dist_version | deb_version |
 +-----------+-------------------+--------------+-------------+
 | HTTP-Tiny | libhttp-tiny-perl | 0.070        | 0.070-1     |
 | Data-Dmp  | libdata-dmp-perl  | 0.22         | 0.21-1      |
 +-----------+-------------------+--------------+-------------+

Reverse the filter (only show dists which do not have Debian packages):

 % lcpan debian-dist2deb --no-exists-on-debian --use-allpackages < dists.txt
 +-----------+-------------------+--------------+-------------+
 | dist      | deb               | dist_version | deb_version |
 +-----------+-------------------+--------------+-------------+
 | App-lcpan | libapp-lcpan-perl | 1.014        |             |
 | Foo       | libfoo-perl       |              |             |
 +-----------+-------------------+--------------+-------------+

Only show dists where the Debian package exists on Debian repo *and* the Debian
package version is less than the dist version:

 % lcpan debian-dist2deb --exists-on-debian --use-allpackages --needs-update < dists.txt
 +-----------+-------------------+--------------+-------------+
 | dist      | deb               | dist_version | deb_version |
 +-----------+-------------------+--------------+-------------+
 | Data-Dmp  | libdata-dmp-perl  | 0.22         | 0.21-1      |
 +-----------+-------------------+--------------+-------------+


=head1 DESCRIPTION
