package Koha::BareAuthority;

use Moose;
use Koha;
use Koha::Changelog::DBLog;
use Koha::HeadingMap;
use C4::Context;
use MARC::Record;
use MARC::Field;
use Digest::SHA1;
use Encode qw(encode_utf8);
use TryCatch;
use Method::Signatures;

with 'Koha::MarcRecord';
with 'Koha::DbRecord';
with 'Koha::Indexable';

has 'rcn' => (
    is => 'ro',
    isa => 'Str',
    lazy_build => 1,
    );

method _build_marc {
    return MARC::Record->new_from_usmarc($self->dbrec->{marc});
}

method _build_rcn {
    if ($self->has_marc) {
        try {
            return sprintf( '(%s)%s',
                            $self->marc->field('003')->data,
                            $self->marc->field('001')->data );
        }
        catch ($e) {
            Koha::BareAuthority::Xcp::BadData->throw(
                'Authority missing 001 or 003');
        }
    }
    else {
        return $self->dbrec->{rcn};
    }
}

method _build_id {
    if ($self->has_marc) {
        return $self->marc->subfield('999', 'e');
    }
    elsif ($self->has_dbrec || $self->has_rcn) {
        return $self->dbrec->{authid};
    }
    else {
        Koha::BareAuthority::Xcp::BadData->throw(
            'Unable to determine authority ID');
    }
}

method _build_dbrec {
    my @args;
    if ($self->has_id) {
        @args = ('authid = ?', $self->id);
    }
    elsif ($self->has_rcn) {
        @args = ('rcn = ?', $self->rcn);
    }
    elsif ($self->has_marc) {
        @args = ('authid = ?', $self->marc->subfield('999', 'e'));
    }
    else {
        Koha::BareAuthority::Xcp::BadData->throw(
            'Unable to sync authority data source');
    }

    return C4::Context->dbh->selectrow_hashref(
        'SELECT * FROM auth_header WHERE ' . $args[0], undef, $args[1] );
}

method _build_changelog {
    return Koha::Changelog::DBLog->new( rtype => 'auth' )
}

method _cache_me {
    my $hash = Digest::SHA1::sha1_base64( encode_utf8($self->csearch_string) );
    C4::Context->dbh->do(
        'INSERT INTO auth_cache (authid, tag) VALUES (?,?)
         ON DUPLICATE KEY UPDATE tag = ?',
        undef, $self->id, $hash, $hash);
}

method _insert {
    # Insert a dummy row to reserve a definite authid
    C4::Context->dbh->do(
        'INSERT INTO auth_header (rcn, authtypecode, marc, marcxml) VALUES (?,?,?,?)',
        undef, '', '', '', '');

    my $id = C4::Context->dbh->last_insert_id(undef, undef, undef, undef);

    # Make sure the critical fields are correct
    my $marc = $self->marc;
    if ( !$marc->field('001') ) {
        $marc->insert_fields_ordered(
            MARC::Field->new('001', $id) );
    }

    if ( !$marc->field('003') ) {
        $marc->insert_fields_ordered(
            MARC::Field->new('003', C4::Context->preference('MARCOrgCode')) );
    }

    my $stub_flag = $self->is_stub ? 1 : 0;
    if ( my ($f999) = $marc->field('999') ) {
        $marc->delete_fields( $f999 );
    }
    $marc->insert_fields_ordered(
        MARC::Field->new('999', '', '', e => $id, z => $stub_flag) );

    if ( my ($f942) = $marc->field('942') ) {
        $f942->update(a => $self->typecode);
    }
    else {
        $marc->insert_fields_ordered(
            MARC::Field->new('942', '', '', a => $self->typecode) );
    }

    $self->_update;
    $self->_cache_me;
}

method _delete {
    C4::Context->dbh->do(
        'DELETE FROM auth_header WHERE authid = ?', undef, $self->id );
    $self->changelog->update($self->id, 'delete');
}

method _update {
    $self->clear_rcn
        if $self->has_marc;

    unless ( $self->marc->field('999') ) {
        $self->marc->insert_fields_ordered(
            MARC::Field->new('999', '', '', e => $self->id) );
    }

    C4::Context->dbh->do(
        'UPDATE auth_header SET rcn = ?, authtypecode = ?, marc = ?, marcxml = ? WHERE authid = ?',
        undef, $self->rcn, $self->typecode,
        $self->marc->as_usmarc, $self->marc->as_xml, $self->id);

    $self->changelog->update($self->id, 'update');
}

func _field2cstr( MARC::Field $f, Str $subfields = 'a-z68' ) {
    return join '', map {"\$$_->[0]$_->[1]"}
        grep {$_->[0] =~ qr([$subfields])} $f->subfields;
}

method csearch_string {
    # Emit canonical search string
    my ($f) = $self->marc->field('1..');
    return _field2cstr($f);
}

func new_stub_from_field(Str $class, MARC::Field $f, Str $citation = undef) {
    my $heading_info = Koha::HeadingMap::bib_headings->{$f->tag}
        || Koha::Xcp->throw($f->tag.' is not a heading field');

    my $typecode = $heading_info->{auth_type};
    my ($auth_type) = grep {$_->{authtypecode} eq $typecode}
        values %{Koha::HeadingMap::auth_types()};

    my $valid_subfields = Koha::HeadingMap::bib_headings->{$f->tag}{subfields};
    my @subfs_1xx = map { $_->[0] => $_->[1] }
        grep { $_->[0] =~ /[$valid_subfields]/ } $f->subfields;

    my $marc = MARC::Record->new;
    $marc->encoding('UTF-8');
    $marc->leader('     nz  a22     o  4500');

    my @tags = (
        [ $auth_type->{auth_tag_to_report}, '', '', @subfs_1xx ],
        [ '667', '', '', 'a' => 'Machine generated authority record.' ],
        [ '999', '', '', 'z' => 1],
    );
    push @tags, [ '670', '', '', 'a' => $citation ]
        if $citation;
    $marc->insert_fields_ordered( MARC::Field->new(@$_) ) for @tags;

    return Koha::BareAuthority->new( marc => $marc );
}

# $f is a controlled bib field, like a 1xx, 6xx, 7xx, etc.
func new_from_field_search(Str $class, MARC::Field $f) {
    # first see if there's a cached entry
    my $cstr = _field2cstr(
        $f, Koha::HeadingMap::bib_headings->{$f->tag}{subfields});
    my $hash = Digest::SHA1::sha1_base64( encode_utf8($cstr) );
    my $cached_authid = C4::Context->dbh->selectrow_arrayref(
        'SELECT authid FROM auth_cache WHERE tag = ?', undef, $hash );
    return $class->new( id => $cached_authid->[0] )
        if $cached_authid;

    # if not, look in the Solr index, choosing the most recently updated
    my $query = Koha::Solr::Query->new(
        query => qq{coded-heading_s:"$cstr"},
        rtype => 'auth',
        options => {fl=>'rcn', sort=>'timestamp desc', rows=>1} );
    my $solr = Koha::Solr::Service->new;
    my $rs = $solr->search( $query->query, $query->options);

    Koha::Xcp->throw($rs->content->{error}{msg}) if $rs->is_error;
    my $resultset = $rs->content;
    Koha::BareAuthority::Xcp::NoMatch->throw("No match for $cstr")
        if $resultset->{response}{numFound} < 1;

    my $rcn = $resultset->{response}{docs}[0]{rcn};
    return $class->new( rcn => $rcn );
}

method is_stub {
    return $self->marc->subfield('999', 'z');
}

method typecode {
    my ($f1xx) = $self->marc->field('1..');
    return Koha::HeadingMap::auth_types->{$f1xx->tag}{authtypecode};
}

method type {
    my ($type) =
        grep { $_->{authtypecode} eq $self->typecode }
        values %{Koha::HeadingMap::auth_types()};
    return $type;
}

method code_labels( Bool $forlibrarian, Str $authtypecode = $self->typecode ) {
    my $dbh = C4::Context->dbh;
    my $libfield = ($forlibrarian) ? 'liblibrarian' : 'libopac';

    my $sth;
    my %res;

    $sth = $dbh->prepare(
        "SELECT tagfield tag, $libfield lib, mandatory, repeatable
         FROM auth_tag_structure
         WHERE authtypecode=?
         ORDER BY tagfield" );
    $sth->execute($authtypecode);
    while ( my ( $tag, $lib, $mandatory, $repeatable ) = $sth->fetchrow ) {
        $res{$tag}{lib}        = $lib;
        $res{$tag}{tab}        = " ";
        $res{$tag}{mandatory}  = $mandatory;
        $res{$tag}{repeatable} = $repeatable;
    }

    $sth = $dbh->prepare(
        "SELECT tagfield tag, tagsubfield, $libfield lib, tab, mandatory,
           repeatable, authorised_value, frameworkcode AS authtypecode,
           value_builder, kohafield, seealso, hidden, isurl
         FROM auth_subfield_structure
         WHERE authtypecode=?
         ORDER BY tagfield, tagsubfield" );
    $sth->execute($authtypecode);

    while (
        my ( $tag, $subfield, $lib, $tab, $mandatory, $repeatable,
             $authorised_value, $authtypecode, $value_builder, $kohafield,
             $seealso, $hidden, $isurl, $link )
        = $sth->fetchrow
        )
    {
        $res{$tag}{$subfield}{lib}              = $lib;
        $res{$tag}{$subfield}{tab}              = $tab;
        $res{$tag}{$subfield}{mandatory}        = $mandatory;
        $res{$tag}{$subfield}{repeatable}       = $repeatable;
        $res{$tag}{$subfield}{authorised_value} = $authorised_value;
        $res{$tag}{$subfield}{authtypecode}     = $authtypecode;
        $res{$tag}{$subfield}{value_builder}    = $value_builder;
        $res{$tag}{$subfield}{kohafield}        = $kohafield;
        $res{$tag}{$subfield}{seealso}          = $seealso;
        $res{$tag}{$subfield}{hidden}           = $hidden;
        $res{$tag}{$subfield}{isurl}            = $isurl;
        $res{$tag}{$subfield}{link}             = $link;
    }

    return \%res;
}

method summary {
    my %summary;
    $summary{heading} =
        join q{}, map { $_->as_string } $self->marc->field('1..');
    $summary{seealso} =
        [ map { { text => $_->as_string } } $self->marc->field('5..') ];
    $summary{seefrom} =
        [ map { { text => $_->as_string } } $self->marc->field('4..') ];

    return \%summary;
}

__PACKAGE__->meta->make_immutable;
no Moose;

{
    package Koha::BareAuthority::Xcp::NoMatch;
    use Moose;
    extends 'Koha::Xcp';

    no Moose;

    package Koha::BareAuthority::Xcp::BadData;
    use Moose;
    extends 'Koha::Xcp';

    no Moose;
}

1;