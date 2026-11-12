type Gen isolated client object {
    isolated remote function generate(string p, typedesc<anydata> td = <>) returns td|error;
};

isolated client class Wrapper {
    *Gen;
    private final Gen inner;
    isolated function init(Gen inner) { self.inner = inner; }
    isolated remote function generate(string p, typedesc<anydata> td = <>) returns td|error {
        return self.inner->generate(p, td);
    }
}

public function main() {}
