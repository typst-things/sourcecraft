#import "../src/lib.typ": source-diagram

#let src = `
/**
 * Javadoc comment block for class
 * /* nested comment markers */
 */
public class Persona {
    private String nombre; // Inline comment after field
    /* Multi-line comment inside class body
       int ignoredField;
    */
    private int edad; // Another inline comment

    /**
     * Javadoc constructor
     */
    public Persona(String nombre) {
        this.nombre = nombre; // "string inside comment"
    }

    public String getNombre() {
        return "http://example.com/test"; // URL with // inside string literal
    }
}
`.text

#source-diagram(src, grammar: "java")
