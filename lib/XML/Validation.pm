package XML::Validation;
require Exporter;
use strict;
use Data::Dumper;
use vars qw(@ISA @EXPORT);
@ISA    = qw ( Exporter );
@EXPORT = qw (
  load_dtd
  validate_xml
);

sub validate_xml {

    my ( $log, $doc, $dtd ) = @_;
    my ($dtd_str);

    #
    # if there's a problem with the dtd then we can't validate the xml
    #
    #

    return 0 if ( !defined $dtd );

    eval { $doc->validate($dtd) };
    $@ && do {

        $log->error("XML failed to validate:\n $@");

        return 0;
    };

    #
    # xml validates, so return true
    #

    return 1;
}

sub load_dtd {

    my ( $log, $dtd_file ) = @_;

    my ( $dtd_str, $dtd );

    #
    # it's probably a good idea to tell someone if we can't open the dtd
    #

    open( IN, $dtd_file ) || do {

        $log->error("Couldn't open $dtd for reading dtd: $!");
        return undef;
    };

    while (<IN>) { $dtd_str .= $_; }
    eval { $dtd = XML::LibXML::Dtd->parse_string($dtd_str); };
    $@ && do {

        $log->error("Couldn't parse dtd string: $@");
        return undef;
    };

    return $dtd;
}
