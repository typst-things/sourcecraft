#[derive(Debug)]
pub struct Cachorro<'a, T: Clone> {
    nome: String,          // '{' no comentario
    pub(crate) idade: u8,
    dono: Option<&'a Dono>,
    coleira: Coleira,
    brinquedos: Vec<Box<Brinquedo>>,
    porte: Porte,
    extra: T,
}

impl<'a, T: Clone> Cachorro<'a, T> {
    pub fn new(nome: String, coleira: Coleira) -> Self {
        let c = 'x';
        Cachorro { nome, idade: 0, dono: None, coleira, brinquedos: vec![], porte: Porte::Medio, extra: todo!() }
    }
    pub fn latir(&self, vezes: u32) -> String { "au".repeat(vezes as usize) }
    pub fn brincar(&mut self, b: Brinquedo) {}
    fn segredo(&self) {}
}

impl<'a, T: Clone> Animal for Cachorro<'a, T> {
    const PATAS: u8 = 4;
    fn nome(&self) -> &str { &self.nome }
    fn novo(nome: String) -> Self { unimplemented!() }
}

impl Alimentavel for Cachorro<'_, i32> {
    fn comer(&mut self, comida: &Comida) -> u32 { comida.calorias }
}

impl std::fmt::Display for Cachorro<'_, i32> {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result { write!(f, "{}", r#"ra{w"#) }
}
