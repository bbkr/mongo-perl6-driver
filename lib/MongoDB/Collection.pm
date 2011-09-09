class MongoDB::Collection;

use MongoDB::Cursor;

has MongoDB::DataBase $.database is rw;
has Str $.name is rw;

submethod BUILD ( MongoDB::DataBase $database, Str $name ) {

    $.database = $database;

    # TODO validate name
    $.name = $name;
}

method insert ( *@documents ) {
    MongoDB.wire.OP_INSERT( self, 0, ||@documents );
}

method find ( %query = { } ) {

    return MongoDB::Cursor.new(
        collection  => self,
        query       => %query,
    );
}

method update ( %selector, %update ) {
    MongoDB.wire.OP_UPDATE( self, %selector, %update );
}

method delete ( %selector = { } ) {
    MongoDB.wire.OP_DELETE( self, %selector );
}

